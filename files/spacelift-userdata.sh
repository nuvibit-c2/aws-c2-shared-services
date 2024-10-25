#!/bin/bash
configure_permissions () {(
  set -e

  if [[ \"${RunLauncherAsSpaceliftUser}\" == \"false\" ]]; then
    echo \"Skipping permission configuration and running the launcher as root\"
  else
    echo \"Creating Spacelift user and setting permissions\" >> /var/log/spacelift/info.log
    adduser --uid=\"1983\" spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
    chown -R spacelift /opt/spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log

    # The info log will have been created by previous log messages, but let's ensure that
    # the error.log file exists, and that the spacelift user owns both files
    touch /var/log/spacelift/error.log
    chown -R spacelift /var/log/spacelift

    echo \"User and permissions are GO\" >> /var/log/spacelift/info.log
  fi
)}

download_launcher() {(
  echo \"Downloading Spacelift launcher from S3\" >> /var/log/spacelift/info.log
  aws s3api get-object --region=${AWS_REGION} --bucket ${BINARIES_BUCKET} --key spacelift-launcher /usr/bin/spacelift-launcher >> /var/log/spacelift/info.log 2>>/var/log/spacelift/error.log

  echo \"Making the Spacelift launcher executable\" >> /var/log/spacelift/info.log
  chmod 755 /usr/bin/spacelift-launcher 2>>/var/log/spacelift/error.log

  echo \"Launcher binary is GO\" >> /var/log/spacelift/info.log
)}

configure_docker () {(
  set -e

  if [[ \"${RunLauncherAsSpaceliftUser}\" == \"true\" ]]; then
    echo \"Adding spacelift user to Docker group\" >> /var/log/spacelift/info.log
    usermod -aG docker spacelift 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  fi

  if [[ \"${HTTP_PROXY_CONFIG}\" != \"\" || \"${HTTPS_PROXY_CONFIG}\" != \"\" || \"${NO_PROXY_CONFIG}\" != \"\" ]]; then
    echo \"Configuring HTTP proxy information for Docker\" >> /var/log/spacelift/info.log

    mkdir -p /etc/systemd/system/docker.service.d 2>>/var/log/spacelift/error.log

    echo \"[Service]\" > /etc/systemd/system/docker.service.d/http-proxy.conf 2>>/var/log/spacelift/error.log

    if [[ \"${HTTP_PROXY_CONFIG}\" != \"\" ]]; then
      echo \"Setting HTTP_PROXY environment variable\" >> /var/log/spacelift/info.log
      echo \"Environment=\\\"HTTP_PROXY=${HTTP_PROXY_CONFIG}\\\"\" >> /etc/systemd/system/docker.service.d/http-proxy.conf
    fi

    if [[ \"${HTTPS_PROXY_CONFIG}\" != \"\" ]]; then
      echo \"Setting HTTPS_PROXY environment variable\" >> /var/log/spacelift/info.log
      echo \"Environment=\\\"HTTPS_PROXY=${HTTPS_PROXY_CONFIG}\\\"\" >> /etc/systemd/system/docker.service.d/http-proxy.conf
    fi

    if [[ \"${NO_PROXY_CONFIG}\" != \"\" ]]; then
      echo \"Setting NO_PROXY environment variable\" >> /var/log/spacelift/info.log
      echo \"Environment=\\\"NO_PROXY=${NO_PROXY_CONFIG}\\\"\" >> /etc/systemd/system/docker.service.d/http-proxy.conf
    fi

    echo \"Restarting Docker daemon to load proxy configuration\" >> /var/log/spacelift/info.log
    systemctl daemon-reload 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
    systemctl restart docker 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  fi

  echo \"Docker configuration is GO\" >> /var/log/spacelift/info.log
)}

load_custom_ca_certs () {(
  set -e

  if [[ \"${ADDITIONAL_ROOT_CAS_SECRET_NAME}\" != \"\" ]]; then
    echo \"Loading custom root CA certificates from ${ADDITIONAL_ROOT_CAS_SECRET_NAME}\" >> /var/log/spacelift/info.log
    local additional_root_cas
    additional_root_cas=$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${ADDITIONAL_ROOT_CAS_SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString')
    
    if [[ \"$additional_root_cas\" = \"\" ]]; then
      echo \"Warning: could not load custom root CA certificates from ${ADDITIONAL_ROOT_CAS_SECRET_NAME}. The error log may contain more information.\" >> /var/log/spacelift/info.log
    fi

    # Add the certificates to the system trust store
    DECODED=$(echo \"$additional_root_cas\" | base64 -d)
    echo \"$DECODED\" | jq -r '.caCertificates[]' | while read -r cert; do
      echo \"$cert\" | base64 -d > /etc/pki/ca-trust/source/anchors/$(uuidgen).crt
    done

    sudo update-ca-trust

    echo \"Custom root CA certificates are GO\" >> /var/log/spacelift/info.log
  fi
)}

create_spacelift_launcher_script () {(
  set -e

  echo \"Creating run-launcher.sh script\" >> /var/log/spacelift/info.log

  local custom_user_data
  if [[ \"${CustomUserDataSecretName}\" != \"\" ]]; then
    echo \"Loading custom user data from ${CustomUserDataSecretName}\" >> /var/log/spacelift/info.log
    custom_user_data=$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${CustomUserDataSecretName} 2>>/var/log/spacelift/error.log | jq -r '.SecretString')
    
    if [[ \"$custom_user_data\" = \"\" ]]; then
      echo \"Warning: could not load custom user data from ${CustomUserDataSecretName}. The error log may contain more information.\" >> /var/log/spacelift/info.log
    fi
  fi

  launcher_script=$(cat <<EOF
#!/bin/bash

join_strings () { local d=\"$1\"; echo -n \"$2\"; shift 2 && printf '%s' \"$${!@/#/$d}\"; }

echo \"Getting worker pool token and private key from Secrets Manager\" >> /var/log/spacelift/info.log
export SPACELIFT_TOKEN=\\$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString' | jq -r '.SPACELIFT_TOKEN')
export SPACELIFT_POOL_PRIVATE_KEY=\\$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString' | jq -r '.SPACELIFT_POOL_PRIVATE_KEY')

echo \"Retrieving EC2 instance ID and ami ID\" >> /var/log/spacelift/info.log
export SPACELIFT_METADATA_instance_id=\\$(ec2-metadata --instance-id | cut -d ' ' -f2)
export SPACELIFT_METADATA_ami_id=\\$(ec2-metadata --ami-id | cut -d ' ' -f2)

echo \"Retrieving EC2 ASG ID\" >> /var/log/spacelift/info.log
export SPACELIFT_METADATA_asg_id=\\$(aws autoscaling --region=${AWS_REGION} describe-auto-scaling-instances --instance-ids \\$SPACELIFT_METADATA_instance_id | jq -r '.AutoScalingInstances[0].AutoScalingGroupName')

if [[ \"${HTTP_PROXY_CONFIG}\" != \"\" || \"${HTTPS_PROXY_CONFIG}\" != \"\" || \"${NO_PROXY_CONFIG}\" != \"\" ]]; then
  whitelisted_vars=()

  echo \"Configuring HTTP proxy information\" >> /var/log/spacelift/info.log

  if [[ \"${HTTP_PROXY_CONFIG}\" != \"\" ]]; then
    echo \"Setting HTTP_PROXY environment variable\" >> /var/log/spacelift/info.log
    export HTTP_PROXY=\"${HTTP_PROXY_CONFIG}\"
    whitelisted_vars+=(\"HTTP_PROXY\")
  fi

  if [[ \"${HTTPS_PROXY_CONFIG}\" != \"\" ]]; then
    echo \"Setting HTTPS_PROXY environment variable\" >> /var/log/spacelift/info.log
    export HTTPS_PROXY=\"${HTTPS_PROXY_CONFIG}\"
    whitelisted_vars+=(\"HTTPS_PROXY\")
  fi

  if [[ \"${NO_PROXY_CONFIG}\" != \"\" ]]; then
    echo \"Setting NO_PROXY environment variable\" >> /var/log/spacelift/info.log
    export NO_PROXY=\"${NO_PROXY_CONFIG}\"
    whitelisted_vars+=(\"NO_PROXY\")
  fi

  formatted_whitelist=\\$(join_strings \",\" \"\\$${!whitelisted_vars[@]}\")
  export SPACELIFT_WHITELIST_ENVS=\"\\$formatted_whitelist\"
fi

if [[ \"${ADDITIONAL_ROOT_CAS_SECRET_NAME}\" != \"\" ]]; then
  echo \"Loading custom root CA certificates from ${ADDITIONAL_ROOT_CAS_SECRET_NAME}\" >> /var/log/spacelift/info.log
  export ADDITIONAL_ROOT_CAS=\\$(aws secretsmanager get-secret-value --region=${AWS_REGION} --secret-id ${ADDITIONAL_ROOT_CAS_SECRET_NAME} 2>>/var/log/spacelift/error.log | jq -r '.SecretString')
  
  if [[ \"\\$ADDITIONAL_ROOT_CAS\" = \"\" ]]; then
    echo \"Warning: could not load custom root CA certificates from ${ADDITIONAL_ROOT_CAS_SECRET_NAME}. The error log may contain more information.\" >> /var/log/spacelift/info.log
  fi
fi

$custom_user_data

echo \"Starting the Spacelift binary\" >> /var/log/spacelift/info.log
/usr/bin/spacelift-launcher

EOF
)

  echo \"$launcher_script\" > /opt/spacelift/run-launcher.sh
  chmod +x /opt/spacelift/run-launcher.sh

  echo \"run-launcher.sh script is GO\" >> /var/log/spacelift/info.log
)}

run_spacelift () {(
  set -e

  echo \"Starting run-launcher.sh script\" >> /var/log/spacelift/info.log

  if [[ \"${RunLauncherAsSpaceliftUser}\" == \"false\" ]]; then
    echo \"Running the launcher as root\" >> /var/log/spacelift/info.log
    /opt/spacelift/run-launcher.sh 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  else
    echo \"Running the launcher as spacelift (UID 1983)\" >> /var/log/spacelift/info.log
    runuser -l spacelift -c '/opt/spacelift/run-launcher.sh' 1>>/var/log/spacelift/info.log 2>>/var/log/spacelift/error.log
  fi
)}

configure_permissions
download_launcher
configure_docker
load_custom_ca_certs
create_spacelift_launcher_script
run_spacelift

if [[ \"${POWER_OFF_ON_ERROR}\" == \"true\" ]]; then
  echo \"Powering off in 15 seconds\" >> /var/log/spacelift/error.log
  sleep 15
  poweroff
fi