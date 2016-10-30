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
             /*"/bin/curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/setmysqlpassword.sh > /tmp/setmysqlpassword.sh && /bin/sudo /bin/bash /tmp/setmysqlpassword.sh ${aws_instance.vault.private_ip}" */
             "/bin/true"
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
               "VAULT_TOKEN=$(/usr/bin/sudo cat /root/vault.txt | grep Root | awk '{print $4}') /usr/local/bin/vault write -tls-skip-verify mysql/config/connection connection_url=\"vault:$(openssl rand -base64 32)@tcp(${aws_instance.database.public_ip}:3306)/\" verify_connection=false",
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
