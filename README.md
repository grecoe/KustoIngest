# Kusto Ingest

Simple example of scanning Azure Subscriptions for information about Azure Resource Groups (Powershell) and then ingesting the data into multiple Azure Kusto DB tables.

What you'll need to continue
- Powershell 7.0 or later with Azure Extension
- Azure CLI
- Python and Miniconda (you can change to use a python venv but this uses conda)
- Azure Subscription(s)

## Setup 

### Set up your environment

Open up a command prompt window (Windows) and after navigating to this folder, execute the following commands.

```bash
conda env create -f environment.yml
conda activate KustoEnv
```

Now set up your connections you'll need

```bash
pwsh -Command Connect-AzAccount
az login
```

### Get info from, or set up Kusto environment

This Kusto environment is where data will be ingested. You will need to ensure that your credentials (used with az login) has rights to the service. Once you have one (which you will need for configuration later), create the following tables in it.

```bash
.create table InstanceView ( Timestamp:datetime, Subscription:string, Instance:string, Group:string)

.create table ClusterView ( Timestamp:datetime, Subscription:string, Instance:string, Cluster:string)

.create table PartitionView ( Timestamp:datetime, Subscription:string, Instance:string, Partition:string)

.create table DCPView ( Timestamp:datetime, Subscription:string, User:string, Group:string, SubType:string, Version:string)
```

### Modify the program/settings.json file

You'll need to have access to at least 1 Azure Subscription in which the code will scan. Update the ***Subscriptions*** array.

Next, you'll need to enter in information about your Kusto cluster and Database that you used above. Change the cluster and database settings. If you created the tables as listed above, you are all set no need to change anything else. 

## Executing 

You can run each of the scripts in the program/ folder separately on the command line such as

```bash
pwsh -File ./instances_get.ps1 -Configuration settings.json
python instances_load.py -Configuration settings.json
```

Or you can just execute them together using 

```
execute_flow.bat
```

## Additional Resources

https://learn.microsoft.com/en-us/azure/data-explorer/python-ingest-data
