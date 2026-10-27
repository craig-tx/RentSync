#!/usr/bin/env bash
# Runs rentsync-deploy on one deployment's host through SSM Run Command, and waits for a host
# that is being replaced (feature 002 research R9). Called by .github/workflows/deploy-to.yml.
#
#   infra/release/run-deploy.sh <deployment_id> <rentsync-deploy argument>
#
# A merge that changes host files starts an HCP Terraform host replacement and a release at the
# same time. The deploy can then reach the old host as it shuts down, find no tagged host, or
# reach the new host before cloud-init has installed Docker. So:
#   - the host waits for cloud-init to finish before running rentsync-deploy;
#   - the command is sent again, after a pause, when no host matched or the host never finished
#     it (killed, unreachable, or an exit code rentsync-deploy itself never uses), until
#     RUN_DEPLOY_DEADLINE_S. A rerun is safe: rentsync-deploy of the running tag is a no-op.
#   - an outcome from rentsync-deploy itself (0, 1 rolled back, 2 unhealthy, 3 not recorded,
#     64 bad argument, 75 lock busy) is final.
#
# Test overrides: RUN_DEPLOY_DEADLINE_S, RUN_DEPLOY_RETRY_DELAY_S, RUN_DEPLOY_POLL_S
# (infra/release/test/run_deploy_test.sh).
set -euo pipefail

deployment_id="$1"
arg="$2"
deadline=$((SECONDS + ${RUN_DEPLOY_DEADLINE_S:-1500}))
retry_delay="${RUN_DEPLOY_RETRY_DELAY_S:-30}"
poll="${RUN_DEPLOY_POLL_S:-5}"

# SSM caps a comment at 100 characters; the pinned argument alone is 112. The comment names the
# deployment and the commit, without the digest.
comment="rentsync-deploy $deployment_id ${arg%%@*}"
commands="[\"cloud-init status --wait > /dev/null || true\", \"/usr/local/bin/rentsync-deploy $arg\"]"

attempt=0
while :; do
  attempt=$((attempt + 1))
  command_id="$(aws ssm send-command \
    --document-name AWS-RunShellScript \
    --targets "Key=tag:DeploymentId,Values=$deployment_id" "Key=tag:rentsync:deployable,Values=true,protected" \
    --parameters "commands=$commands" \
    --timeout-seconds 900 --comment "$comment" \
    --query Command.CommandId --output text)"
  echo "attempt $attempt: SSM command $command_id"

  status=None
  for _ in $(seq 1 180); do
    status="$(aws ssm list-command-invocations --command-id "$command_id" \
      --query 'CommandInvocations[0].Status' --output text)"
    case "$status" in Pending|InProgress|Delayed|None) sleep "$poll" ;; *) break ;; esac
  done
  instance="$(aws ssm list-command-invocations --command-id "$command_id" \
    --query 'CommandInvocations[0].InstanceId' --output text)"

  if [ "$instance" = "None" ]; then
    reason="no instance tagged DeploymentId=$deployment_id and rentsync:deployable (true or protected)"
  else
    aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" \
      --query '[StandardOutputContent, StandardErrorContent]' --output text
    code="$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" \
      --query ResponseCode --output text)"
    echo "status: $status (exit $code) on $instance"
    case "$code" in
      0) [ "$status" = Success ] && exit 0 ;;
      1 | 2 | 3 | 64 | 75) exit 1 ;;
    esac
    reason="the host did not finish the deploy (status $status, exit $code); it may be being replaced"
  fi

  if [ $((SECONDS + retry_delay)) -ge "$deadline" ]; then
    echo "giving up: $reason"
    exit 1
  fi
  echo "$reason; trying again in ${retry_delay}s"
  sleep "$retry_delay"
done
