#!/bin/bash
configure_permissions () {(
  set -e

  if [[ "${RunLauncherAsSpaceliftUser}" == "false" ]]; then
    echo "Skipping permission configuration and running the launcher as root"
  else
    echo "Creating Spacelift user and setting permissions" >> /var/log/spacelift/info.log
    adduser --uid="1983" spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
    chown -R spacelift /opt/spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log

    # The info log will have been created by previous log messages, but let's ensure that
    # the error.log file exists, and that the spacelift user owns both files
    touch /var/log/spacelift/error.log
    chown -R spacelift /var/log/spacelift

    echo "User and permissions are GO" >> /var/log/spacelift/info.log
  fi
)}

download_launcher() {(
  echo "Downloading Spacelift launcher from S3" >> /var/log/spacelift/info.log
  aws s3api get-object --region=${AWS_REGION} --bucket ${BINARIES_BUCKET} --key spacelift-launcher /usr/bin/spacelift-launcher >> /var/log/spacelift/info.log 2>>/var/log/spacelift/error.log

  echo "Making the Spacelift launcher executable" >> /var/log/spacelift/info.log
  chmod 755 /usr/bin/spacelift-launcher 2>>/var/log/spacelift/error.log

  echo "Launcher binary is GO" >> /var/log/spacelift/info.log
)}

configure_docker () {(
  set -e

  if [[ "${RunLauncherAsSpaceliftUser}" == "true" ]]; then
    echo "Adding spacelift user to Docker group" >> /var/log/spacelift/info.log
    usermod -aG docker spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  fi

  echo "Docker configuration is GO" >> /var/log/spacelift/info.log
)}

create_spacelift_launcher_script () {(
  set -e

  echo "Creating run-launcher.sh script" >> /var/log/spacelift/info.log
  launcher_script=$(cat <<EOF
#!/bin/bash

join_strings () { local d="$1"; echo -n "$2"; shift 2 && printf '%s' "$${!@/#/$d}"; }

echo "Getting worker pool token and private key from Secrets Manager" >> /var/log/spacelift/info.log
export SPACELIFT_TOKEN=$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString' | jq -r '.SPACELIFT_TOKEN')
export SPACELIFT_POOL_PRIVATE_KEY=$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString' | jq -r '.SPACELIFT_POOL_PRIVATE_KEY')

echo "Retrieving EC2 instance ID and ami ID" >> /var/log/spacelift/info.log
export SPACELIFT_METADATA_instance_id=$(ec2-metadata --instance-id | cut -d ' ' -f2)
export SPACELIFT_METADATA_ami_id=$(ec2-metadata --ami-id | cut -d ' ' -f2)

echo "Retrieving EC2 ASG ID" >> /var/log/spacelift/info.log
export SPACELIFT_METADATA_asg_id=$(aws autoscaling --region=${AWS_REGION} describe-auto-scaling-instances --instance-ids $SPACELIFT_METADATA_instance_id | jq -r '.AutoScalingInstances[0].AutoScalingGroupName')

### INSERT CUSTOM USER DATA HERE

echo "Starting the Spacelift binary" >> /var/log/spacelift/info.log
/usr/bin/spacelift-launcher

EOF
)

  echo "$launcher_script" > /opt/spacelift/run-launcher.sh
  chmod +x /opt/spacelift/run-launcher.sh

  echo "run-launcher.sh script is GO" >> /var/log/spacelift/info.log
)}

run_spacelift () {(
  set -e

  echo "Starting run-launcher.sh script" >> /var/log/spacelift/info.log

  if [[ "${RunLauncherAsSpaceliftUser}" == "false" ]]; then
    echo "Running the launcher as root" >> /var/log/spacelift/info.log
    /opt/spacelift/run-launcher.sh 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  else
    echo "Running the launcher as spacelift (UID 1983)" >> /var/log/spacelift/info.log
    runuser -l spacelift -c '/opt/spacelift/run-launcher.sh' 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  fi
)}

configure_permissions
download_launcher
configure_docker
create_spacelift_launcher_script
run_spacelift

if [[ "${POWER_OFF_ON_ERROR}" == "true" ]]; then
  echo "Powering off in 15 seconds" >> /var/log/spacelift/error.log
  sleep 15
  poweroff
fi