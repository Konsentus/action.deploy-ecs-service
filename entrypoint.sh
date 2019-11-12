#!/bin/bash -l

## Standard ENV variables provided
# ---
# GITHUB_ACTION=The name of the action
# GITHUB_ACTOR=The name of the person or app that initiated the workflow
# GITHUB_EVENT_PATH=The path of the file with the complete webhook event payload.
# GITHUB_EVENT_NAME=The name of the event that triggered the workflow
# GITHUB_REPOSITORY=The owner/repository name
# GITHUB_BASE_REF=The branch of the base repository (eg the destination branch name for a PR)
# GITHUB_HEAD_REF=The branch of the head repository (eg the source branch name for a PR)
# GITHUB_REF=The branch or tag ref that triggered the workflow
# GITHUB_SHA=The commit SHA that triggered the workflow
# GITHUB_WORKFLOW=The name of the workflow that triggerdd the action
# GITHUB_WORKSPACE=The GitHub workspace directory path. The workspace directory contains a subdirectory with a copy of your repository if your workflow uses the actions/checkout action. If you don't use the actions/checkout action, the directory will be empty

# for logging and returning data back to the workflow,
# see https://help.github.com/en/articles/development-tools-for-github-actions#logging-commands
# echo ::set-output name={name}::{value}
# -- DONT FORGET TO SET OUTPUTS IN action.yml IF RETURNING OUTPUTS

# exit with a non-zero status to flag an error/failure

# Ensures required environment variables are supplied by workflow
check_env_vars() {
  local requiredVariables=(
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_ACCOUNT_ROLE"
    "AWS_REGION"
  )

  for variable_name in "${requiredVariables[@]}"
  do
    if [[ -z "${!variable_name}" ]]; then
      echo "Required environment variable: $variable_name is not defined. Exiting"
      return 3;
    fi
  done
}

assume_role() {
  echo "Assuming role: $AWS_ACCOUNT_ROLE in account: $aws_account_id"

  local credentials
  credentials=$(aws sts assume-role --role-arn "arn:aws:iam::$aws_account_id:role/$AWS_ACCOUNT_ROLE" --role-session-name ecs-force-refresh --output json)
  assume_role_result=$?

  if [ $assume_role_result -ne 0 ]; then
    echo "Failed to assume role $AWS_ACCOUNT_ROLE in account: $AWS_ACCOUNT_ID. Exiting"
    return $assume_role_result
  fi

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  export AWS_DEFAULT_REGION=$AWS_REGION

  AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<< $credentials)
  AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<< $credentials)
  AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<< $credentials)

  echo "Successfully assumed role"
}

deploy_service_task() {
  echo "Forcing deployment of the $service_name service in the $cluster_name cluster"

  local service_metadata
  service_metadata=$(aws ecs update-service --cluster $cluster_name --service $INPUT_SERVICE_NAME --force-new-deployment)
  local exitCode=$?

  if [ $exitCode -ne 0 ]; then
    echo "Failed to force new deployment of the $service_name service in the $cluster_name cluster. Exiting"
    return $exitCode
  fi
}

wait_for_service_to_stabilise() {
  echo "Waiting for the service to stabilise"

  aws ecs wait services-stable --cluster $cluster_name --services $INPUT_SERVICE_NAME
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo "Failed to wait for the stabilisation of the $service_name service in the $cluster_name cluster. Exiting"
    return $exit_code
  fi
  echo "Service has stabilised"
}

truncate_long_string() {
  echo $1 | sed -E 's/(.{5})(.{1,})$/\1/'
}

check_task_container_digest() {
  echo "Checking container image digests"

  echo "Expected image digest: $INPUT_EXPECTED_IMAGE_DIGEST"
  echo "Retrieving task ARNs"
  local running_tasks=$(aws ecs list-tasks --cluster $cluster_name --service-name $service_name --desired-status RUNNING | jq .taskArns)

  for task_arn in $(echo "$running_tasks" | jq -r '.[]'); do
    echo "Retrieving image digest for task: $task_arn"
    local task_image_digest=$(aws ecs describe-tasks --tasks $task_arn --cluster $cluster_name | jq -r .tasks[0].containers[0].imageDigest)

    if [ "$task_image_digest" == "$INPUT_EXPECTED_IMAGE_DIGEST" ]; then
      echo "The image digest for task: $task_arn matches the expected image digest"
      return 0
    else
      echo "The image digest for task: $task_arn does not match the expected image digest: $task_image_digest"
      return 3
    fi
  done
}

echo "Force new ECS deployment"

# Get branch name
# e.g. return "master" from "refs/heads/master"
branch_name=${GITHUB_REF##*/}

aws_account_id=$(echo $INPUT_ENVIRONMENT_CONFIGURATION | jq -r .$branch_name.awsAccountId)
cluster_name=$(echo $INPUT_ENVIRONMENT_CONFIGURATION | jq -r .$branch_name.clusterName)
service_name=$INPUT_SERVICE_NAME

echo "Target cluster: $cluster_name"
echo "Target service: $service_name"

check_env_vars || exit $?

assume_role || exit $?

deploy_service_task || exit $?

wait_for_service_to_stabilise || exit $?

check_task_container_digest || exit $?
