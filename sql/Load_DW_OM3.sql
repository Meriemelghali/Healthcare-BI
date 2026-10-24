/* =============================================================================
   Healthcare BI - Load DW, aligné sur le schéma en constellation de l'équipe
   Base DW : HealthcareDW (schéma dwh)  |  Staging : HealthcareDB_Staging (schéma stg)

   Couvre : les 3 dimensions conformées (DIM_TEMPS, DIM_PATIENT, DIM_SEJOUR),
            DIM_MEDICAMENT (colonnes du modèle) et F6 = FACT_PRESCRIPTION.

   Ordre dans SSIS :  DIM_TEMPS, DIM_PATIENT, DIM_SEJOUR, DIM_MEDICAMENT  ->  puis F6.
   Rappel : DIM_SERVICE sert à F3, F4 et F5 (garder le flux existant).
            DIM_VOIE_ADMINISTRATION n'existe pas dans le modèle : "route" est dans
            DIM_MEDICAMENT, donc le flux DF_DIM_VOIE peut être désactivé.
   ============================================================================= */

USE HealthcareDW;
GO
IF SCHEMA_ID(N'dwh') IS NULL EXEC (N'CREATE SCHEMA dwh');
GO

/* ========================== 1. CRÉATION DES TABLES ========================== */

IF OBJECT_ID(N'dwh.FACT_PRESCRIPTION') IS NOT NULL DROP TABLE dwh.FACT_PRESCRIPTION;
IF OBJECT_ID(N'dwh.DIM_MEDICAMENT')    IS NOT NULL DROP TABLE dwh.DIM_MEDICAMENT;   -- recréée avec les colonnes du modèle
GO

IF OBJECT_ID(N'dwh.DIM_TEMPS') IS NULL
CREATE TABLE dwh.DIM_TEMPS (
    date_sk        int          NOT NULL CONSTRAINT pk_dim_temps PRIMARY KEY,   -- AAAAMMJJ ; -1 = date inconnue
    date_complete  date         NULL,
    jour           tinyint      NULL,
    mois           tinyint      NULL,
    trimestre      tinyint      NULL,
    annee          smallint     NULL,
    semaine        tinyint      NULL,
    jour_semaine   nvarchar(10) NULL
);
GO

IF OBJECT_ID(N'dwh.DIM_PATIENT') IS NULL
CREATE TABLE dwh.DIM_PATIENT (
    patient_sk                int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_patient PRIMARY KEY,
    subject_id                int           NOT NULL CONSTRAINT uq_dim_patient UNIQUE,
    gender                    nvarchar(5)   NULL,
    dob                       date          NULL,
    age                       smallint      NULL,   -- âge à la 1re admission ; 90 = "90 ans et plus"
    expire_flag               smallint      NULL,
    dod                       date          NULL,
    dod_hosp                  date          NULL,
    dod_ssn                   date          NULL,
    HeightInMeters            decimal(5,2)  NULL,
    WeightInKilograms         decimal(7,2)  NULL,
    BMI                       decimal(6,2)  NULL,
    HadHeartAttack            smallint NULL, HadAngina            smallint NULL, HadStroke        smallint NULL,
    HadAsthma                 smallint NULL, HadSkinCancer        smallint NULL, HadCOPD          smallint NULL,
    HadDepressiveDisorder     smallint NULL, HadKidneyDisease     smallint NULL, HadArthritis     smallint NULL,
    HadDiabetes               nvarchar(60) NULL,
    DeafOrHardOfHearing       smallint NULL, BlindOrVisionDifficulty smallint NULL, DifficultyConcentrating smallint NULL,
    DifficultyWalking         smallint NULL, DifficultyDressingBathing smallint NULL, DifficultyErrands smallint NULL,
    SmokerStatus              nvarchar(60) NULL,
    ECigaretteUsage           nvarchar(60) NULL,
    ChestScan                 smallint     NULL
);
GO

IF OBJECT_ID(N'dwh.DIM_SEJOUR') IS NULL
CREATE TABLE dwh.DIM_SEJOUR (
    sejour_sk            int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_sejour PRIMARY KEY,
    hadm_id              int           NOT NULL CONSTRAINT uq_dim_sejour UNIQUE,
    subject_id           int           NOT NULL,       -- lien vers DIM_PATIENT
    admission_type       nvarchar(50)  NULL,
    admission_location   nvarchar(80)  NULL,
    discharge_location   nvarchar(80)  NULL,
    insurance            nvarchar(50)  NULL,
    language             nvarchar(50)  NULL,
    religion             nvarchar(60)  NULL,
    marital_status       nvarchar(50)  NULL,
    ethnicity            nvarchar(100) NULL,
    edregtime            datetime2(0)  NULL,
    edouttime            datetime2(0)  NULL,
    diagnosis            nvarchar(300) NULL,
    hospital_expire_flag smallint      NULL,
    has_chartevents_data smallint      NULL
);
GO

CREATE TABLE dwh.DIM_MEDICAMENT (
    medicament_sk       int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_medicament PRIMARY KEY,
    drug_name_generic   nvarchar(255) NOT NULL,
    drug                nvarchar(255) NOT NULL,
    drug_type           nvarchar(50)  NOT NULL,
    route               nvarchar(50)  NOT NULL
);
GO

CREATE TABLE dwh.FACT_PRESCRIPTION (
    prescription_sk         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_prescription PRIMARY KEY,
    row_id                  int NOT NULL CONSTRAINT uq_fact_prescription UNIQUE,   -- identifiant source
    patient_sk              int NOT NULL CONSTRAINT fk_f6_patient REFERENCES dwh.DIM_PATIENT (patient_sk),
    sejour_sk               int NOT NULL CONSTRAINT fk_f6_sejour  REFERENCES dwh.DIM_SEJOUR (sejour_sk),
    date_start_sk           int NOT NULL CONSTRAINT fk_f6_start   REFERENCES dwh.DIM_TEMPS (date_sk),
    date_end_sk             int NOT NULL CONSTRAINT fk_f6_end     REFERENCES dwh.DIM_TEMPS (date_sk),   -- -1 si inconnue
    medicament_sk           int NOT NULL CONSTRAINT fk_f6_medic   REFERENCES dwh.DIM_MEDICAMENT (medicament_sk),
    dose                    decimal(18,4) NULL,   -- NULL si plage ("5-10") ou texte
    dose_unite              nvarchar(20)  NULL,   -- ajout : sans l'unité, additionner des doses n'a pas de sens (à retirer si l'équipe refuse)
    duree_traitement_jours  int           NULL,   -- NULL si date de fin inconnue
    nb_prescriptions        int NOT NULL CONSTRAINT df_f6_nb DEFAULT 1
);
GO

/* ===================== 2. DIM_TEMPS (OLE DB Source, SQL command) ==================
   Les dates MIMIC sont décalées : vos données vont de 2102 à 2202.                  */
;WITH n AS (
    SELECT TOP (DATEDIFF(DAY, '2100-01-01', '2203-01-01'))
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c
), d AS (SELECT DATEADD(DAY, i, CAST('2100-01-01' AS date)) AS dt FROM n)
SELECT  CAST(CONVERT(char(8), dt, 112) AS int)      AS date_sk,
        dt                                          AS date_complete,
        CAST(DAY(dt) AS tinyint)                    AS jour,
        CAST(MONTH(dt) AS tinyint)                  AS mois,
        CAST(DATEPART(QUARTER, dt) AS tinyint)      AS trimestre,
        CAST(YEAR(dt) AS smallint)                  AS annee,
        CAST(DATEPART(ISO_WEEK, dt) AS tinyint)     AS semaine,
        CAST(DATENAME(WEEKDAY, dt) AS nvarchar(10)) AS jour_semaine
FROM d;
GO
-- Execute SQL Task APRÈS ce flux : la ligne "date inconnue"
IF NOT EXISTS (SELECT 1 FROM dwh.DIM_TEMPS WHERE date_sk = -1) INSERT dwh.DIM_TEMPS (date_sk) VALUES (-1);
GO
/* Heure / plage (nuit-jour) de l'image : impossible dans une table au grain "jour".
   Si vous les voulez, il faut soit une DIM_HEURE séparée, soit une DIM_TEMPS au grain "heure". */

/* ======================= 3. DIM_PATIENT (OLE DB Source) =======================
   Dates PATIENTS en texte dans stg -> TRY_CONVERT (valeur invalide = NULL, pas d'erreur).
   Email et city ne sont pas repris (non présents dans le modèle).
   Âge : les patients de plus de 89 ans sont décalés de ~300 ans par MIMIC -> plafonné à 90. */
SELECT  TRY_CONVERT(int, p.subject_id)                                   AS subject_id,
        CAST(p.gender AS nvarchar(5))            AS gender,
        TRY_CONVERT(date, LEFT(CAST(p.dob AS nvarchar(30)), 10))         AS dob,
        CASE WHEN a.first_adm IS NULL OR TRY_CONVERT(date, LEFT(CAST(p.dob AS nvarchar(30)),10)) IS NULL THEN NULL
             WHEN DATEDIFF(YEAR, TRY_CONVERT(date, LEFT(CAST(p.dob AS nvarchar(30)),10)), a.first_adm) > 89 THEN 90
             ELSE DATEDIFF(YEAR, TRY_CONVERT(date, LEFT(CAST(p.dob AS nvarchar(30)),10)), a.first_adm) END AS age,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.expire_flag))         AS expire_flag,
        TRY_CONVERT(date, LEFT(CAST(p.dod      AS nvarchar(30)), 10))    AS dod,
        TRY_CONVERT(date, LEFT(CAST(p.dod_hosp AS nvarchar(30)), 10))    AS dod_hosp,
        TRY_CONVERT(date, LEFT(CAST(p.dod_ssn  AS nvarchar(30)), 10))    AS dod_ssn,
        TRY_CONVERT(decimal(5,2), TRY_CONVERT(float, p.HeightInMeters))      AS HeightInMeters,
        TRY_CONVERT(decimal(7,2), TRY_CONVERT(float, p.WeightInKilograms))   AS WeightInKilograms,
        TRY_CONVERT(decimal(6,2), TRY_CONVERT(float, p.BMI))                 AS BMI,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadHeartAttack))      AS HadHeartAttack,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadAngina))           AS HadAngina,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadStroke))           AS HadStroke,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadAsthma))           AS HadAsthma,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadSkinCancer))       AS HadSkinCancer,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadCOPD))             AS HadCOPD,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadDepressiveDisorder)) AS HadDepressiveDisorder,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadKidneyDisease))    AS HadKidneyDisease,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.HadArthritis))        AS HadArthritis,
        CAST(p.HadDiabetes AS nvarchar(60))      AS HadDiabetes,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.DeafOrHardOfHearing))       AS DeafOrHardOfHearing,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.BlindOrVisionDifficulty))   AS BlindOrVisionDifficulty,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.DifficultyConcentrating))   AS DifficultyConcentrating,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.DifficultyWalking))         AS DifficultyWalking,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.DifficultyDressingBathing)) AS DifficultyDressingBathing,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.DifficultyErrands))         AS DifficultyErrands,
        CAST(p.SmokerStatus AS nvarchar(60))     AS SmokerStatus,
        CAST(p.ECigaretteUsage AS nvarchar(60))  AS ECigaretteUsage,
        TRY_CONVERT(smallint, TRY_CONVERT(float, p.ChestScan))           AS ChestScan
FROM stg.PATIENTS p
OUTER APPLY (SELECT MIN(TRY_CONVERT(date, LEFT(CAST(x.admittime AS nvarchar(30)),10))) AS first_adm
             FROM stg.ADMISSIONS x WHERE x.subject_id = p.subject_id) a
WHERE TRY_CONVERT(int, p.subject_id) IS NOT NULL;
GO

/* ======================== 4. DIM_SEJOUR (OLE DB Source) ======================== */
SELECT  TRY_CONVERT(int, hadm_id)                 AS hadm_id,
        TRY_CONVERT(int, subject_id)              AS subject_id,
        CAST(admission_type AS nvarchar(50))     AS admission_type,
        CAST(admission_location AS nvarchar(80)) AS admission_location,
        CAST(discharge_location AS nvarchar(80)) AS discharge_location,
        CAST(insurance AS nvarchar(50))          AS insurance,
        CAST(language AS nvarchar(50))           AS language,
        CAST(religion AS nvarchar(60))           AS religion,
        CAST(marital_status AS nvarchar(50))     AS marital_status,
        CAST(ethnicity AS nvarchar(100))         AS ethnicity,
        TRY_CONVERT(datetime2(0), edregtime)      AS edregtime,
        TRY_CONVERT(datetime2(0), edouttime)      AS edouttime,
        CAST(diagnosis AS nvarchar(300))          AS diagnosis,
        TRY_CONVERT(smallint, TRY_CONVERT(float, hospital_expire_flag)) AS hospital_expire_flag,
        TRY_CONVERT(smallint, TRY_CONVERT(float, has_chartevents_data)) AS has_chartevents_data
FROM stg.ADMISSIONS
WHERE TRY_CONVERT(int, hadm_id) IS NOT NULL;
GO

/* ===================== 5. DIM_MEDICAMENT (OLE DB Source) ======================
   Un médicament = (nom générique, nom, type, voie).  Le nom générique manque dans 44,5 % des
   lignes : on prend alors "drug".  UPPER/TRIM partout : le Lookup SSIS est sensible à la casse,
   pas SQL Server ; la même expression doit être utilisée ici ET dans la source de la fait.   */
SELECT DISTINCT
        CAST(UPPER(TRIM(COALESCE(NULLIF(TRIM(drug_name_generic), ''), drug))) AS nvarchar(255)) AS drug_name_generic,
        CAST(UPPER(TRIM(drug)) AS nvarchar(255))      AS drug,
        CAST(UPPER(TRIM(drug_type)) AS nvarchar(50))  AS drug_type,
        CAST(UPPER(TRIM(route)) AS nvarchar(50))      AS route
FROM stg.PRESCRIPTIONS
WHERE drug IS NOT NULL AND drug_type IS NOT NULL AND route IS NOT NULL;
GO

/* ================== 6. F6 = FACT_PRESCRIPTION (OLE DB Source) ===================
   Avant : Execute SQL Task  ->  TRUNCATE TABLE dwh.FACT_PRESCRIPTION
   Grain : 1 ligne de prescription.
   Ensuite 5 Lookups (Full cache, "No match" -> sortie d'erreur) :
     subject_id   -> DIM_PATIENT.patient_sk
     hadm_id      -> DIM_SEJOUR.sejour_sk
     date_start_sk-> DIM_TEMPS.date_sk          date_end_sk -> DIM_TEMPS.date_sk (un 2e Lookup : même table, rôle "fin")
     drug_name_generic + drug + drug_type + route (les 4 colonnes) -> DIM_MEDICAMENT.medicament_sk */
SELECT  TRY_CONVERT(int, row_id)     AS row_id,
        TRY_CONVERT(int, subject_id) AS subject_id,
        TRY_CONVERT(int, hadm_id)    AS hadm_id,
        CAST(CONVERT(char(8), TRY_CONVERT(date, LEFT(CAST(startdate AS nvarchar(30)),10)), 112) AS int)           AS date_start_sk,
        ISNULL(CAST(CONVERT(char(8), TRY_CONVERT(date, LEFT(CAST(enddate AS nvarchar(30)),10)), 112) AS int), -1) AS date_end_sk,
        CAST(UPPER(TRIM(COALESCE(NULLIF(TRIM(drug_name_generic), ''), drug))) AS nvarchar(255)) AS drug_name_generic,
        CAST(UPPER(TRIM(drug)) AS nvarchar(255))      AS drug,
        CAST(UPPER(TRIM(drug_type)) AS nvarchar(50))  AS drug_type,
        CAST(UPPER(TRIM(route)) AS nvarchar(50))      AS route,
        TRY_CONVERT(decimal(18,4), dose_val_rx) AS dose,
        CAST(dose_unit_rx AS nvarchar(20))      AS dose_unite,
        DATEDIFF(DAY, TRY_CONVERT(date, LEFT(CAST(startdate AS nvarchar(30)),10)),
                      TRY_CONVERT(date, LEFT(CAST(enddate   AS nvarchar(30)),10))) AS duree_traitement_jours
FROM stg.PRESCRIPTIONS
WHERE drug IS NOT NULL AND drug_type IS NOT NULL AND route IS NOT NULL;
GO

/* ============================== 7. CONTRÔLES =============================== */
SELECT 'stg.PRESCRIPTIONS' AS t, COUNT(*) AS n FROM stg.PRESCRIPTIONS UNION ALL
SELECT 'F6 FACT_PRESCRIPTION',   COUNT(*) FROM dwh.FACT_PRESCRIPTION UNION ALL   -- attendu = stg
SELECT 'DIM_PATIENT (100)',      COUNT(*) FROM dwh.DIM_PATIENT UNION ALL
SELECT 'DIM_SEJOUR (129)',       COUNT(*) FROM dwh.DIM_SEJOUR UNION ALL
SELECT 'DIM_MEDICAMENT',         COUNT(*) FROM dwh.DIM_MEDICAMENT;

SELECT SUM(CASE WHEN dose IS NULL THEN 1 ELSE 0 END)                   AS doses_null,
       SUM(CASE WHEN duree_traitement_jours IS NULL THEN 1 ELSE 0 END) AS durees_null,
       SUM(CASE WHEN date_end_sk = -1 THEN 1 ELSE 0 END)               AS fin_inconnue
FROM dwh.FACT_PRESCRIPTION;
