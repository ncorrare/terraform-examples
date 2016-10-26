provider "aws" {
  region                   = "${var.aws_region}"
  shared_credentials_file  = "/Users/ncorrare/.aws/credentials"
  profile                  = "default"
}
