# Before running, you will need to download the EC2 tools from http://aws.amazon.com/developertools/351
# and then setup your EC2_HOME and PATH variables (or similar):
# 
# # Setup environment for ec2-api-tools
# export EC2_HOME=/path/to/ec2-api-tools-1.6.7.4/
# export PATH=$PATH:$EC2_HOME/bin
# export AWS_ACCESS_KEY=
# export AWS_SECRET_KEY=

# Check for ec2 commands we require and die if they're missing
type ec2-create-keypair >/dev/null 2>&1 || { echo >&2 "I require ec2-create-keypair but it's not installed.  Aborting."; exit 1; }
type ec2-create-group >/dev/null 2>&1 || { echo >&2 "I require ec2-create-group but it's not installed.  Aborting."; exit 1; }
type ec2-authorize >/dev/null 2>&1 || { echo >&2 "I require ec2-authorize but it's not installed.  Aborting."; exit 1; }
type ec2-run-instances >/dev/null 2>&1 || { echo >&2 "I require ec2-run-instances but it's not installed.  Aborting."; exit 1; }
type ec2-describe-instances >/dev/null 2>&1 || { echo >&2 "I require ec2-describe-instances but it's not installed.  Aborting."; exit 1; }

# Create a keypair for our servers
echo "Removing old keypair for druid..."
ec2-delete-keypair druid-keypair
echo "Creating new keypair for druid..."
ec2-create-keypair druid-keypair > druid-keypair
chmod 0600 druid-keypair
mv druid-keypair ~/.ssh/

# Create a security group for our servers
echo "Creating a new security group for druid..."
ec2-create-group druid-group -d "Druid Cluster"

# Create rules that allow necessary services in our group
echo "Creating new firewall rules for druid..."
# SSH from outside
ec2-authorize druid-group -P tcp -p 22
# Enable all traffic within group
ec2-authorize druid-group -P tcp -p 1-65535 -o druid-group
ec2-authorize druid-group -P udp -p 1-65535 -o druid-group

echo "Booting a single small instance for druid..."
# Use ami ami-e7582d8e - Alestic Ubuntu 12.04 us-east
INSTANCE_ID=$(ec2-run-instances ami-e7582d8e -n 1 -g druid-group -k druid-keypair --instance-type m1.small| awk '/INSTANCE/{print $2}')
while true; do
    sleep 1
    INSTANCE_STATUS=$(ec2-describe-instances|grep INSTANCE|grep $INSTANCE_ID|grep -v grep|cut -f6)
    if [ $INSTANCE_STATUS == "running" ]
        then
            echo "Instance $INSTANCE_ID is status $INSTANCE_STATUS..."
            break
    fi
done

# Wait for the instance to come up
echo "Waiting 60 seconds for instance $INSTANCE_ID to boot..."
sleep 60

# Get hostname and ssh with the key we created, and ssh there
INSTANCE_ADDRESS=`ec2-describe-instances|grep 'INSTANCE'|grep $INSTANCE_ID|cut -f4`
echo "Connecting to $INSTANCE_ADDRESS to prepare environment for druid..."
ssh -i ~/.ssh/druid-keypair -o StrictHostKeyChecking=no ubuntu@${INSTANCE_ADDRESS} <<\EOI
  # Install dependencies - mysql and Java, and setup druid db
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get -q -y install mysql-server

  # Is localhost expected with multi-node?
  mysql -u root -e "GRANT ALL ON druid.* TO 'druid'@'localhost' IDENTIFIED BY 'diurd'; CREATE database druid;"

  # Setup Oracle Java
  sudo apt-get purge openjdk*
  sudo rm /var/lib/dpkg/info/oracle-java7-installer*
  sudo apt-get purge oracle-java7-installer*
  sudo rm /etc/apt/sources.list.d/*java*
  sudo apt-get update
  sudo add-apt-repository -y ppa:webupd8team/java
  sudo apt-get update
  
  # Setup yes answer to license question
  echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
  echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
  sudo apt-get -y install oracle-java7-installer
  
  # Automated Kafka setup
  curl http://static.druid.io/artifacts/kafka-0.7.2-incubating-bin.tar.gz -o /tmp/kafka-0.7.2-incubating-bin.tar.gz
  tar -xvzf /tmp/kafka-0.7.2-incubating-bin.tar.gz
  cd kafka-0.7.2-incubating-bin
  cat config/zookeeper.properties
  nohup bin/zookeeper-server-start.sh config/zookeeper.properties &
  # in a new console
  nohup bin/kafka-server-start.sh config/server.properties &
  
  # Logout
  exit
EOI

echo "Prepared $INSTANCE_ADDRESS for druid."
