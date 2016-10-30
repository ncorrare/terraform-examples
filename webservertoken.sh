#!/bin/bash
VAULTHOST=$1
/bin/curl -L https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 > /bin/jq
chmod +x /bin/jq
AUTH_TOKEN=$(/bin/curl -X POST -k "https://$VAULTHOST:8200/v1/auth/aws-ec2/login" -d '{"role":"example","pkcs7":"'$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/pkcs7 | tr -d '\n')'"}' | tee /tmp/response | /bin/jq .auth.client_token | tr -d \")
if [ "$?" -eq "0" ] && [ ! -z "$AUTH_TOKEN" ]; then
  sleep 10
  echo $AUTH_TOKEN > /etc/vaulttoken 
else
  echo "Vault token couldn't be obtained"	
  exit 1
fi
