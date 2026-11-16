# AHU – Application Hub Updater

Mise à jour automatique d'applications Windows avec **GitHub + Intune Remediations**, inspirée de Patch My PC, sans SCCM, serveur interne ni Azure.

Les postes lisent [`catalog/apps.json`](catalog/apps.json). Pour faire évoluer une application, on modifie son manifeste JSON : aucune application Intune ni règle de détection à recréer.

- Documentation : [docs/README.md](docs/README.md)
- Architecture et analyse Patch My PC / Robopack : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Scripts Intune à téléverser : [`intune/Detection.ps1`](intune/Detection.ps1) et [`intune/Remediation.ps1`](intune/Remediation.ps1)
