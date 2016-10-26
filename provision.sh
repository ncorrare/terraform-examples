#!/bin/bash
rpm -Uvh http://yum.puppetlabs.com/puppetlabs-release-el-7.noarch.rpm
rpm -Uvh http://yum.puppetlabs.com/el/7Server/PC1/x86_64/puppetlabs-release-pc1-1.1.0-4.el7.noarch.rpm
yum -y install puppet-agent git
export PATH=$PATH:/opt/puppetlabs/bin/:/opt/puppetlabs/puppet/bin
/opt/puppetlabs/puppet/bin/gem install r10k
mkdir /etc/puppetlabs/r10k
curl https://raw.githubusercontent.com/ncorrare/terraform-examples/master/r10k.yaml > /etc/puppetlabs/r10k/r10k.yaml
/opt/puppetlabs/puppet/bin/r10k deploy environment -p
