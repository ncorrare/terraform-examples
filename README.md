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

Two security groups are created, one that allows only SSH access and another one that allows SSH and HTTP from outside the VPC. All communication between servers is done through the VPC, and it's irresctricted (don't do this at home, always create separate VPC's and restrict access between them to only the necessary ports).

Finally, the demo application deployed will query consul for the different elements of the infrastructure, and Vault for a set of readonly credentials to access the MySQL database. The code for the application is on https://github.com/ncorrare/hashidemo.

# How-to
This example operates within the following assumptions:
- Terraform is installed
- You have an AWS account, and an existing ssh key pair to login into the hosts
- You're deploying on either eu-west-1, us-west-1 or us-west-2 (if not, you need to add the AMI-id for RHEL 7 as part of the aws_amis map in vars.tf)
- Your AWS credentials have permissions to create ec2 instances, vpcs, security groups, and load balancer.
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
```terraform apply -var 'sshkey={your_aws_key_name}' \
   -var 'keypath={location_of_your_key_in_your_local_machine}'\
   -var 'awsaccountid={your_aws_account_id}'``` 

The deployment will take about 15-20 to complete depending on the usual factors. 


Once the deployment is finished it will return the list of hosts deployed. You can ssh into each host individually to explore how they were configured, issuing an ssh ec2-user@${host} -i ${path to the private key}. To access the consul UI, ssh ec2-user@${consulhost} -i ${path to the private key} -L 8500:localhost:8500, and then open http://localhost:8500/ in a browser. Terraform will output the ssh commands to login into each system.

Ultimately, Terraform will display the domain name of the load balancer where you'll be able to reach a page that describes where is each component in the infrastructure and connects to MySQL obtaining readonly credentials from Vault.


# Workflow
- A VPC using the specified subnet is created, as well as two security groups. Both with SSH access and only one with Web Access. Both security groups allow outbound communication, and inbound from inside the VPC. An internet gateway and route is created as well, to satisfy all basic network requirements.

- An IAM user, role and instance profile (as well as their respective policies) are created so Vault can authenticate systems gaining access to the credentials. There is a single role created, assigned to the default policy in Vault.

- An initial server for the Consul cluster is created, the Puppet Agent (see provision.sh script, and the control repository with the appropiate Puppet code) is provisioned and invoked to set the base configuration, as well as Consul and it's UI.

- The database server is created, the Puppet Agent is provisioned and invoked to install a basic MySQL database, and joins the Consul cluster with a check for MySQL.

- A vault server is created, invoking Puppet for the base configuration and Vault instalation, initialization and unseal. The "one-shot" tasks are executed directly from the provisioner. These tasks include:
  - Enable and configure the AWS authentication backend.
  - Mount mysql
  - Configure a set of credentials with a dynamically generated password for Vault
  - Download & import the policy
It's worth noting that the provisioning process will create a /root/vault.txt file with the initial root token and unseal keys. Clean it up, save it elsewhere or leave it, just be aware.
As with all servers, the consul cluster is joined and a status check is created for the resource.

- The vault provisioning process will trigger a null_resource (mysqlprovisioners) to create the credentials configured in Vault into MySQL. This is done on the database server, obtaining the credentials from Vault and setting them up on MySQL (see setmysqlpassword.sh script)

- The previous null_resource will trigger another null_resource to set a readonly role on Vault (readonlyrole).
- A memcache server is created, the Puppet Agent is provisioned and invoked to configure the system. The consul cluster is joined and a status check is created for the resource.

- A webserver is created to run a sinatra app that consumes those resources (http://github.com/ncorrare/hashidemo). It runs DNS queries into consul to discover the services, and has a quick and dirty function to retrieve credentials from Vault. It attempts to connect to MySQL, and if it fails, it calls the function back to retrieve a new set of credentials (Assuming they have expired).

- A load balancer is created, with a single web server at this time.

# Rationale
- Leverage Terraform language to model cloud infrastructure, and establish relationship between resources at a control plane level.
- Make use of Consul service discovery features to find the different components required for the (simple) application to run.
- Credentials are never stored or transmited in plain text, only through Vault. The application is also leveraging the password expiry and rotation features in Vault.

- The use of Packer (and pre-existing Puppet code) could accelerate the deployment, starting with pre-configured golden images, that Puppet could maintain over time.

# Manual Cleanups
- Please set a root password for the MySQL database, even if it only allows access from localhost.
- Store /root/vault.txt from the vault server elsewhere. Those unseal tokens are needed every time the service restarts.
- Bare in mind that the token that the application uses to access vault is on /etc/vaulttoken, and it's not rotated at this time.
