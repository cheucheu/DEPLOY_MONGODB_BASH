### DEPLOY_MONGODB_BASH  

This script allows to deploy automatically a cluster mongodb ( replicaset or sharding) unser KSH 93 and SSH for remote access.
You must use a config file to declare the configuration.

To Run :  install_mongodb.ksh <config.file>
Before read the prerequisites in the shell


If you want to deploy a replicaset configuration, you have just to declare this section:

	###################
	#replicaset config#
	###################

	replicaset=<replicaset name>:<hostname1>:<port1>
	replicaset=<replicaset name>:<hostname2>:<port2>
	replicaset=<replicaset name>:<hostname3>:<port3>

If you want to deploy a sharding conifiguration, you have just to declare this others sections:

	###################
	#replicaset config#
	###################
	replicaset=<replicaset name1>:<hostname1>:<port1>
	replicaset=<replicaset name1>:<hostname2>:<port2>
	replicaset=<replicaset name2>:<hostname3>:<port3>
	replicaset=<replicaset name2>:<hostname4>:<port4>

	#####################
	# servers sharding  #
	#####################
	config=<hostname5>:<port5>
	config=<hostname6>:<port6>
	config=<hostname7>:<port7>
	#################
	#mongos sharding#
	#################
	mongos=<hostname8>:27014
	##########
	#sharding#
	##########
	shard=<name shard1>:<hostname1>
	shard=<name shard2>:<hostname3>

The words replicaset, config, mongos and shard are mandatory to detect the configuration.  You can also define specific roles and users  but the password are not crypted during the installation.


# DEPLOY_MONGODB_BASH
# DEPLOY_MONGODB_BASH
# DEPLOY_MONGODB_BASH
