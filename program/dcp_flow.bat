REM Execute the acquisition of resource groups.
pwsh -File ./dcp_get.ps1 -Configuration settings.json
REM Now upload the results to Kusto
python dcp_load.py -Configuration settings.json