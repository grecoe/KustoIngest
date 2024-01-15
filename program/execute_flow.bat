REM Execute the acquisition of resource groups.
pwsh -File ./instances_get.ps1 -Configuration settings.json
REM Now upload the results to Kusto
python instances_load.py -Configuration settings.json
