resource "aws_vpc" "vpc" {
  cidr_block = "${var.vpc_cidr}"
  enable_dns_hostnames = true
}


resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.vpc.id}"
}

resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.default.id}"
}


resource "aws_subnet" "vpc_subnet" {
  vpc_id = "${aws_vpc.vpc.id}"
  cidr_block = "${var.vpc_cidr}"
  map_public_ip_on_launch = false
}

resource "aws_iam_access_key" "vault" {
    user = "${aws_iam_user.vault.name}"
}

resource "aws_iam_user" "vault" {
    name = "vault"
    path = "/system/"
}

resource "aws_iam_user_policy" "vault" {
    name = "vault"
    user = "${aws_iam_user.vault.name}"
    policy = <<EOF
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
EOF
}

resource "aws_iam_role" "example_role" {
    name = "example_role"
    path = "/"
    assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "example_role_policy" {
    name = "example_role_policy"
    role = "${aws_iam_role.example_role.id}"
    policy = <<EOF
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
EOF
}

resource "aws_iam_instance_profile" "test_profile" {
    name = "test_profile"
    roles = ["${aws_iam_role.example_role.name}"]
}

resource "aws_instance" "consulserver" {
  ami                         = "${lookup(var.aws_amis, var.aws_region)}"
  instance_type               = "t2.micro"
  subnet_id                   = "${aws_subnet.vpc_subnet.id}"
  vpc_security_group_ids      = ["${aws_security_group.vpc.id}"]
  associate_public_ip_address = "true"
  key_name                    = "${var.sshkey}"
  provisioner "remote-exec" {
    inline = "/usr/bin/sudo /sbin/setenforce 0 && /bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/provision.sh | /usr/bin/sudo /bin/bash && /usr/bin/sudo /opt/puppetlabs/bin/puppet apply -e 'include profile::consulserver'"
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${file(var.keypath)}"
    }
  }
}

resource "null_resource" "mysqlprovisioners" {
  triggers {
    vault_servers = "${aws_instance.vault.id}"
  }
  connection {
    host        = "${aws_instance.database.public_ip}"
    type        = "ssh"
    user        = "ec2-user"
    private_key = "${file(var.keypath)}"
  }
  provisioner "remote-exec" {
    inline = [
             "/bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/setmysqlpassword.sh > /tmp/setmysqlpassword.sh && /bin/sudo /bin/bash /tmp/setmysqlpassword.sh ${aws_instance.vault.private_ip}" 
             ]
  }
}

resource "null_resource" "readonlyrole" {
  triggers {
    vault_servers = "${null_resource.mysqlprovisioners.id}"
  }
  connection {
    host        = "${aws_instance.vault.public_ip}"
    type        = "ssh"
    user        = "ec2-user"
    private_key = "${file(var.keypath)}"
  }
  provisioner "remote-exec" {
    inline = [
	     "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault write -tls-skip-verify mysql/roles/readonly sql=\"CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';\""
             ]
  }
}



resource "aws_instance" "vault" {
  ami                         = "${lookup(var.aws_amis, var.aws_region)}"
  depends_on                  = ["aws_instance.consulserver"]
  instance_type               = "t2.micro"
  iam_instance_profile        = "${aws_iam_instance_profile.test_profile.id}"
  subnet_id                   = "${aws_subnet.vpc_subnet.id}"
  vpc_security_group_ids      = ["${aws_security_group.vpc.id}"]
  associate_public_ip_address = "true"
  key_name                    = "${var.sshkey}"
  provisioner "remote-exec" {
    inline = [ 
               "/usr/bin/sudo /sbin/setenforce 0 && /bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/provision.sh | /usr/bin/sudo /bin/bash && sudo /bin/sh -c \"echo 'consulserver: ${aws_instance.consulserver.private_ip}' > /opt/puppetlabs/facter/facts.d/consulserver.yaml\" && /usr/bin/sudo /opt/puppetlabs/bin/puppet apply -e 'include profile::vault'",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault auth-enable -tls-skip-verify aws-ec2",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault write -tls-skip-verify auth/aws-ec2/config/client secret_key=${aws_iam_access_key.vault.secret} access_key=${aws_iam_access_key.vault.id}",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault write -tls-skip-verify auth/aws-ec2/role/example bound_account_id=${var.awsaccountid} policies=default",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault mount -tls-skip-verify mysql",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault write -tls-skip-verify mysql/config/connection connection_url=\"vault:$(openssl rand -base64 32)@tcp(${aws_instance.database.private_ip}:3306)/\" verify_connection=false",
               "/bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/policies.hcl > policies.hcl",
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault policy-write -tls-skip-verify default ./policies.hcl"
               
             ]
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${file(var.keypath)}"
    }
  }
}

resource "aws_instance" "database" {
  ami                         = "${lookup(var.aws_amis, var.aws_region)}"
  depends_on                  = ["aws_instance.consulserver"]
  instance_type               = "t2.micro"
  subnet_id                   = "${aws_subnet.vpc_subnet.id}"
  vpc_security_group_ids      = ["${aws_security_group.vpc.id}"]
  iam_instance_profile        = "${aws_iam_instance_profile.test_profile.id}"
  associate_public_ip_address = "true"
  key_name                    = "${var.sshkey}"
  provisioner "remote-exec" {
    inline = "/usr/bin/sudo /sbin/setenforce 0 && /bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/provision.sh | /usr/bin/sudo /bin/bash && sudo /bin/sh -c \"echo 'consulserver: ${aws_instance.consulserver.private_ip}' > /opt/puppetlabs/facter/facts.d/consulserver.yaml\" && /usr/bin/sudo /opt/puppetlabs/bin/puppet apply -e 'include profile::database'"
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${file(var.keypath)}"
    }
  }
}

resource "aws_instance" "memcache" {
  ami                         = "${lookup(var.aws_amis, var.aws_region)}"
  depends_on                  = ["aws_instance.consulserver"]
  instance_type               = "t2.micro"
  subnet_id                   = "${aws_subnet.vpc_subnet.id}"
  vpc_security_group_ids      = ["${aws_security_group.vpc.id}"]
  iam_instance_profile        = "${aws_iam_instance_profile.test_profile.id}"
  associate_public_ip_address = "true"
  key_name                    = "${var.sshkey}"
  provisioner "remote-exec" {
    inline = "/usr/bin/sudo /sbin/setenforce 0 && /bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/provision.sh | /usr/bin/sudo /bin/bash && sudo /bin/sh -c \"echo 'consulserver: ${aws_instance.consulserver.private_ip}' > /opt/puppetlabs/facter/facts.d/consulserver.yaml\" && /usr/bin/sudo /opt/puppetlabs/bin/puppet apply -e 'include profile::memcache'"
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${file(var.keypath)}"
    }
  }
}

resource "aws_instance" "webserver" {
  ami                         = "${lookup(var.aws_amis, var.aws_region)}"
  depends_on                  = ["aws_instance.database","aws_instance.memcache","aws_instance.vault"]
  instance_type               = "t2.micro"
  subnet_id                   = "${aws_subnet.vpc_subnet.id}"
  vpc_security_group_ids      = ["${aws_security_group.webserver.id}"]
  iam_instance_profile        = "${aws_iam_instance_profile.test_profile.id}"
  associate_public_ip_address = "true"
  key_name                    = "${var.sshkey}"
  provisioner "remote-exec" {
    inline = [ 
               "/usr/bin/sudo /sbin/setenforce 0 && /bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/provision.sh | /usr/bin/sudo /bin/bash && sudo /bin/sh -c \"echo 'consulserver: ${aws_instance.consulserver.private_ip}' > /opt/puppetlabs/facter/facts.d/consulserver.yaml\" && /usr/bin/sudo /opt/puppetlabs/bin/puppet apply -e 'include profile::webserver'",
               "/bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/webservertoken.sh > /tmp/webservertoken.sh && /bin/sudo /bin/bash /tmp/webservertoken.sh ${aws_instance.vault.private_ip}"
             ]
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = "${file(var.keypath)}"
    }
  }
}

resource "aws_elb" "web" {
  name = "terraform-example-elb"

  subnets         = ["${aws_subnet.vpc_subnet.id}"]
  security_groups = ["${aws_security_group.webserver.id}"]
  instances       = ["${aws_instance.webserver.id}"]


  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
}

output "consul" { value = "${aws_instance.consulserver.public_dns}" }
output "vault" { value = "${aws_instance.vault.public_dns}" }
output "MySQL" { value = "${aws_instance.database.public_dns}" }
output "memcache" { value = "${aws_instance.memcache.public_dns}" }
output "webserver" { value = "${aws_instance.webserver.public_dns}" }
/*
output "Instructions" { value = "The Infrastructure is now ready, if you need to login into: 
Consul:
 ssh ec2-user@${aws_instance.consulserver.public_dns} -i ${var.keypath} -L 8500:localhost:8500
This command will map port 8500 from the consul server into localhost to give you access to the UI via http://localhost:8500/
Vault:
 ssh ec2-user@${aws_instance.vault.public_dns} -i ${var.keypath}
Unseal tokens and Initial Root Token are available in the /root/vault.txt file. Please ensure you copy the contents and delete the file.
MySQL:
 ssh ec2-user@${aws_instance.database.public_dns} -i ${var.keypath}
Root access from localhost is available without a password. Credentials for vault have been dynamically generated and stored in Vault.
Memcache:
 ssh ec2-user@${aws_instance.memcache.public_dns} -i ${var.keypath}
Webservers:
 ssh ec2-user@${aws_instance.webserver.public_dns} -i ${var.keypath}

To check the end to end result, you can hit the load balancer in http://${aws_elb.web.dns_name}/
"
}
*/
