Table of Contents
=================

* [Description](#description)
* [How-to](#how-to)
* [Workflow](#workflow)
* [Rationale](#rationale)
* [Manual Cleanups](#manual-cleanups)

# Description
This is proof of concept code, not written up to best practices.
This terraform plan will deploy a simple 4-tier infrastructure (Database, Cache, Application Server, Load Balancer), along with Consul for Service Discovery and Vault for credential storage.

All credentials are generated automatically and stored in vault, that uses consul as a storage backend. Vault is only accesible through SSL using a self-signed certificate. Servers authenticate with Vault throught the AWS Backend.

Every server gets provisioned using the Puppet agent without a master, code gets deployed directly to the agent. The control repository for the different profiles used in this example is in https://github.com/ncorrare/hashi-control-repo.git.

Consul is deployed on all servers, which are joined automatically to the cluster. The UI is only available in a single server, and accessible through ssh tunneling on plain http on the standard port (8500). Puppet can leverage consul's DNS interface to discover different parts of the infrastructure using the consullookup parser function (authored for this example and available as part of the profile module).

Two security groups are created, one that allows only SSH access and another one that allows SSH and HTTP from outside the VPN. All communication between servers is done through the VPC, and it's irresctricted (don't do this at home, always create separate VPC's and restrict access between them to only the necessary ports).

Finally, the demo application deployed will query consul for the different elements of the infrastructure, and Vault for a set of readonly credentials to access the MySQL database.

#How-to
This example operates within the following assumptions:
- Terraform is installed
- You have an AWS account, and an existing ssh key pair to login into the hosts
- You're deploying on either eu-west-1, us-west-1 or us-west-2 (if not, you need to add the AMI-id for RHEL 7 as part of the aws_amis map in vars.tf)
- Your AWS credentials have the necessary privilege to create a role and user with the following policy:
```
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:DescribeInstances",
        "iam:GetInstanceProfile"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
```

Clone this repository, and customize the following variables in the vars.tf file:
- sshkey: Name of the SSH Key Pair (in aws) used to login into the systems
- keypath: Path to the SSH private key used to login into the systems
- awsaccountid: AWS Account ID as shown in the Billing section of the AWS Panel

Alternatively you can issue the following command, customizing the variables at runtime:
```terraform apply -var 'key_name={your_aws_key_name}' \
   -var 'public_key_path={location_of_your_key_in_your_local_machine}'``` 

The deployment will take about 15-20 to complete depending on the usual factors. Once the deployment is finished it will return the list of hosts deployed. You can ssh into each host individually to explore how they were configured, issuing an ssh ec2-user@${host} -i ${path to the private key}. To access the consul UI, ssh ec2-user@${consulhost} -i ${path to the private key} -L 8500:localhost:8500, and then open http://localhost:8500/ in a browser.
