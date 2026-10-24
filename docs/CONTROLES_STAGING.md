# Contrôles du staging

Base : `HealthcareDB_Staging`, schéma `stg`.
Package : `Load_Staging_Area.dtsx`.
Principe : copie brute des 18 fichiers CSV/Excel, avec `load_date` et `source_file`. Aucune transformation.

## Volumes chargés

| Table stg | Lignes | Source | Remarque |
|---|---|---|---|
| ADMISSIONS | 129 | CSV | |
| CALLOUT | 77 | CSV | |
| CHARTEVENTS | 758 355 | CSV | la plus grosse table (75 Mo) |
| D_CPT | 134 | CSV | corrigé : qualificateur de texte `"` nécessaire |
| D_ICD_DIAGNOSES | 14 567 | CSV | |
| D_ITEMS | 12 487 | CSV | |
| D_LABITEMS | 753 | CSV | |
| DATETIMEEVENTS | 15 551 | CSV | |
| INPUTEVENTS_CV | 34 799 | CSV | |
| INPUTEVENTS_MV | 13 224 | CSV | |
| MICROBIOLOGYEVENTS | 2 003 | CSV | |
| NOTEEVENTS | 0 | CSV | fichier source vide (en-tête seul) |
| OUTPUTEVENTS | 11 320 | CSV | |
| PATIENTS | 100 | Excel | |
| PRESCRIPTIONS | 10 398 | CSV | objectif OM3 |
| RECLAMATIONS | 20 | Excel | |
| SERVICES | 163 | CSV | |
| TRANSFERS | 524 | CSV | |

## Contrôles effectués

- Les 18 Data Flows s'exécutent en succès.
- Le `TRUNCATE` en début de package vide les 18 tables avant chaque chargement (autorisé au niveau staging).
- Le nombre de lignes de chaque table est vérifié avec `SELECT COUNT(*)`.
- Seule `NOTEEVENTS` est à 0 : le fichier source ne contient que l'en-tête.