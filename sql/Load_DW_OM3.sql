/* =============================================================================
   Healthcare BI - Load DW OM3 (Prescriptions)  -  VERSION 2
   Base DW : HealthcareDW (schéma dwh)  |  Staging : HealthcareDB_Staging (schéma stg)

   Modifications par rapport à la v1  (repérées par [MODIF]) :
     1. F6 reçoit service_sk -> lien vers DIM_SERVICE (cohérent avec les slides 30-32
        et avec l'objectif OBI 3.5 "analyse par service")
     2. DIM_SERVICE : création si absente + ligne "INCONNU" (-1)
     3. DIM_MEDICAMENT : clé naturelle UNIQUE sur les 4 colonnes (anti-doublons)
     4. DIM_MEDICAMENT : plus de UPDATE dans SSIS (voir étapes)
     5. Contrôles supplémentaires

   Ordre SSIS :  DIM_TEMPS, DIM_PATIENT, DIM_SEJOUR, DIM_SERVICE, DIM_MEDICAMENT  ->  puis F6.
   ============================================================================= */

USE HealthcareDW;
GO
IF SCHEMA_ID(N'dwh') IS NULL EXEC (N'CREATE SCHEMA dwh');
GO

/* ========================== 1. CRÉATION DES TABLES ========================== */

IF OBJECT_ID(N'dwh.FACT_PRESCRIPTION') IS NOT NULL DROP TABLE dwh.FACT_PRESCRIPTION;
IF OBJECT_ID(N'dwh.DIM_MEDICAMENT')    IS NOT NULL DROP TABLE dwh.DIM_MEDICAMENT;
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
    age                       smallint      NULL,
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
    subject_id           int           NOT NULL,
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

/* [MODIF 2] DIM_SERVICE : créée seulement si elle n'existe pas (elle sert aussi à F3, F4, F5) */
IF OBJECT_ID(N'dwh.DIM_SERVICE') IS NULL
CREATE TABLE dwh.DIM_SERVICE (
    service_sk       int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_service PRIMARY KEY,
    service_code     nvarchar(20)  NOT NULL CONSTRAINT uq_dim_service UNIQUE,
    service_libelle  nvarchar(100) NULL
);
GO

/* Ligne "service inconnu" (-1) : fonctionne que service_sk soit IDENTITY ou non */
IF NOT EXISTS (SELECT 1 FROM dwh.DIM_SERVICE WHERE service_sk = -1)
BEGIN
    IF COLUMNPROPERTY(OBJECT_ID(N'dwh.DIM_SERVICE'), 'service_sk', 'IsIdentity') = 1
    BEGIN
        SET IDENTITY_INSERT dwh.DIM_SERVICE ON;
        INSERT dwh.DIM_SERVICE (service_sk, service_code) VALUES (-1, N'INCONNU');
        SET IDENTITY_INSERT dwh.DIM_SERVICE OFF;
    END
    ELSE
        INSERT dwh.DIM_SERVICE (service_sk, service_code) VALUES (-1, N'INCONNU');
END
GO

/* [MODIF 3] clé naturelle UNIQUE sur les 4 colonnes (610 car. = 1 220 octets, OK SQL Server 2016+) */
CREATE TABLE dwh.DIM_MEDICAMENT (
    medicament_sk       int IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_medicament PRIMARY KEY,
    drug_name_generic   nvarchar(255) NOT NULL,
    drug                nvarchar(255) NOT NULL,
    drug_type           nvarchar(50)  NOT NULL,
    route               nvarchar(50)  NOT NULL,
    CONSTRAINT uq_dim_medicament UNIQUE (drug_name_generic, drug, drug_type, route)
);
GO

/* [MODIF 1] service_sk ajouté */
CREATE TABLE dwh.FACT_PRESCRIPTION (
    prescription_sk         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_prescription PRIMARY KEY,
    row_id                  int NOT NULL CONSTRAINT uq_fact_prescription UNIQUE,   -- identifiant source (dimension dégénérée)
    patient_sk              int NOT NULL CONSTRAINT fk_f6_patient REFERENCES dwh.DIM_PATIENT (patient_sk),
    sejour_sk               int NOT NULL CONSTRAINT fk_f6_sejour  REFERENCES dwh.DIM_SEJOUR (sejour_sk),
    date_start_sk           int NOT NULL CONSTRAINT fk_f6_start   REFERENCES dwh.DIM_TEMPS (date_sk),
    date_end_sk             int NOT NULL CONSTRAINT fk_f6_end     REFERENCES dwh.DIM_TEMPS (date_sk),   -- -1 si inconnue
    medicament_sk           int NOT NULL CONSTRAINT fk_f6_medic   REFERENCES dwh.DIM_MEDICAMENT (medicament_sk),
    service_sk              int NOT NULL CONSTRAINT fk_f6_service REFERENCES dwh.DIM_SERVICE (service_sk),  -- -1 si inconnu
    dose                    decimal(18,4) NULL,   -- NULL si plage ("5-10") ou texte
    dose_unite              nvarchar(20)  NULL,
    duree_traitement_jours  int           NULL,   -- date fin - date début ; NULL si fin inconnue
    nb_prescriptions        int NOT NULL CONSTRAINT df_f6_nb DEFAULT 1
);
GO

/* ===================== 2. DIM_TEMPS (OLE DB Source) =============================
   Génère 2100-01-01 -> 2202-12-31 (37 620 jours) + ligne -1.                        */
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
-- Execute SQL Task (déjà placée AVANT le flux dans votre package, c'est correct)
IF NOT EXISTS (SELECT 1 FROM dwh.DIM_TEMPS WHERE date_sk = -1) INSERT dwh.DIM_TEMPS (date_sk) VALUES (-1);
GO

/* ======================= 3. DIM_PATIENT (inchangée) ======================= */
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

/* ======================== 4. DIM_SEJOUR (inchangée) ======================== */
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

/* ===================== 5. DIM_SERVICE (flux existant, inchangé) =================
   Source du flux (déjà dans votre package) :                                        */
SELECT DISTINCT
    curr_service AS service_code,
    CASE curr_service
        WHEN 'CMED'  THEN 'Cardiologie médicale'   WHEN 'CSURG' THEN 'Chirurgie cardiaque'
        WHEN 'GU'    THEN 'Génito-urinaire'        WHEN 'MED'   THEN 'Médecine générale'
        WHEN 'NMED'  THEN 'Neurologie médicale'    WHEN 'NSURG' THEN 'Neurochirurgie'
        WHEN 'OMED'  THEN 'Oncologie médicale'     WHEN 'ORTHO' THEN 'Orthopédie'
        WHEN 'SURG'  THEN 'Chirurgie générale'     WHEN 'TRAUM' THEN 'Traumatologie'
        WHEN 'TSURG' THEN 'Chirurgie thoracique'   WHEN 'VSURG' THEN 'Chirurgie vasculaire'
        ELSE curr_service
    END AS service_libelle
FROM stg.SERVICES
WHERE curr_service IS NOT NULL;
GO

/* ===================== 6. DIM_MEDICAMENT (OLE DB Source) ======================
   Flux SSIS : Source -> Lookup (4 colonnes) -> "sans correspondance" -> Destination.
   [MODIF 4] La sortie "avec correspondance" n'est reliée à RIEN (plus de UPDATE).    */
SELECT DISTINCT
        CAST(UPPER(TRIM(COALESCE(NULLIF(TRIM(drug_name_generic), ''), drug))) AS nvarchar(255)) AS drug_name_generic,
        CAST(UPPER(TRIM(drug)) AS nvarchar(255))      AS drug,
        CAST(UPPER(TRIM(drug_type)) AS nvarchar(50))  AS drug_type,
        CAST(UPPER(TRIM(route)) AS nvarchar(50))      AS route
FROM stg.PRESCRIPTIONS
WHERE drug IS NOT NULL AND drug_type IS NOT NULL AND route IS NOT NULL;
GO

/* ================== 7. F6 = FACT_PRESCRIPTION (OLE DB Source) ===================
   Avant : Execute SQL Task  ->  TRUNCATE TABLE dwh.FACT_PRESCRIPTION
   Grain : 1 ligne de prescription.
   Lookups (Full cache, "Fail component") :
     subject_id        -> DIM_PATIENT.patient_sk
     hadm_id           -> DIM_SEJOUR.sejour_sk
     service_code      -> DIM_SERVICE.service_sk          [MODIF 1]  (nouveau 4e Lookup)
     drug_name_generic + drug + drug_type + route -> DIM_MEDICAMENT.medicament_sk
   Les dates (date_start_sk / date_end_sk) n'ont pas de Lookup : la FK de la base les contrôle.

   [MODIF 1] Service retenu = service actif au jour de début de la prescription
             (dernier transfert <= date de début) ; sinon 1er service du séjour ;
             sinon 'INCONNU' (-> -1).                                                  */
SELECT  TRY_CONVERT(int, p.row_id)     AS row_id,
        TRY_CONVERT(int, p.subject_id) AS subject_id,
        TRY_CONVERT(int, p.hadm_id)    AS hadm_id,
        CAST(CONVERT(char(8), c.start_d, 112) AS int)                    AS date_start_sk,
        ISNULL(CAST(CONVERT(char(8), c.end_d, 112) AS int), -1)          AS date_end_sk,
        CAST(UPPER(TRIM(COALESCE(NULLIF(TRIM(p.drug_name_generic), ''), p.drug))) AS nvarchar(255)) AS drug_name_generic,
        CAST(UPPER(TRIM(p.drug)) AS nvarchar(255))      AS drug,
        CAST(UPPER(TRIM(p.drug_type)) AS nvarchar(50))  AS drug_type,
        CAST(UPPER(TRIM(p.route)) AS nvarchar(50))      AS route,
        ISNULL(sv.service_code, N'INCONNU')             AS service_code,      -- [MODIF 1]
        TRY_CONVERT(decimal(18,4), p.dose_val_rx) AS dose,
        CAST(p.dose_unit_rx AS nvarchar(20))      AS dose_unite,
        DATEDIFF(DAY, c.start_d, c.end_d)         AS duree_traitement_jours
FROM stg.PRESCRIPTIONS p
CROSS APPLY (SELECT TRY_CONVERT(date, LEFT(CAST(p.startdate AS nvarchar(30)),10)) AS start_d,
                    TRY_CONVERT(date, LEFT(CAST(p.enddate   AS nvarchar(30)),10)) AS end_d) c
OUTER APPLY (SELECT TOP (1) CAST(s.curr_service AS nvarchar(20)) AS service_code
             FROM stg.SERVICES s
             WHERE TRY_CONVERT(int, s.hadm_id) = TRY_CONVERT(int, p.hadm_id)
               AND s.curr_service IS NOT NULL
             ORDER BY CASE WHEN TRY_CONVERT(date, LEFT(CAST(s.transfertime AS nvarchar(30)),10)) <= c.start_d THEN 0 ELSE 1 END,
                      CASE WHEN TRY_CONVERT(date, LEFT(CAST(s.transfertime AS nvarchar(30)),10)) <= c.start_d
                           THEN TRY_CONVERT(datetime2(0), s.transfertime) END DESC,
                      TRY_CONVERT(datetime2(0), s.transfertime) ASC) sv
WHERE p.drug IS NOT NULL AND p.drug_type IS NOT NULL AND p.route IS NOT NULL;
GO
/* Destination : [dwh].[FACT_PRESCRIPTION]
   Mappings : row_id, patient_sk, sejour_sk, date_start_sk, date_end_sk, medicament_sk,
              service_sk (NOUVEAU), dose, dose_unite, duree_traitement_jours.
   Sans lien : prescription_sk (identité) et nb_prescriptions (valeur par défaut 1).     */

/* ============================== 8. CONTRÔLES =============================== */
SELECT 'stg.PRESCRIPTIONS' AS t, COUNT(*) AS n FROM stg.PRESCRIPTIONS UNION ALL
SELECT 'F6 FACT_PRESCRIPTION (= stg)', COUNT(*) FROM dwh.FACT_PRESCRIPTION UNION ALL
SELECT 'DIM_PATIENT (100)',        COUNT(*) FROM dwh.DIM_PATIENT UNION ALL
SELECT 'DIM_SEJOUR (129)',         COUNT(*) FROM dwh.DIM_SEJOUR UNION ALL
SELECT 'DIM_SERVICE (13 avec -1)', COUNT(*) FROM dwh.DIM_SERVICE UNION ALL
SELECT 'DIM_MEDICAMENT (913)',     COUNT(*) FROM dwh.DIM_MEDICAMENT UNION ALL
SELECT 'DIM_TEMPS (37 621)',       COUNT(*) FROM dwh.DIM_TEMPS;

SELECT SUM(CASE WHEN dose IS NULL THEN 1 ELSE 0 END)                   AS doses_null,             -- 681 attendu
       SUM(CASE WHEN duree_traitement_jours IS NULL THEN 1 ELSE 0 END) AS durees_null,            -- 40 attendu
       SUM(CASE WHEN duree_traitement_jours < 0 THEN 1 ELSE 0 END)     AS durees_negatives,       -- 0 attendu
       SUM(CASE WHEN date_end_sk = -1 THEN 1 ELSE 0 END)               AS fin_inconnue,
       SUM(CASE WHEN service_sk = -1 THEN 1 ELSE 0 END)                AS sans_service            -- 1 attendu
FROM dwh.FACT_PRESCRIPTION;

-- Test de relance : lancer le package 2 fois, ces 2 requêtes doivent donner le même résultat
SELECT COUNT(*) AS nb_medicaments FROM dwh.DIM_MEDICAMENT;
SELECT drug_name_generic, COUNT(*) AS nb_variantes
FROM dwh.DIM_MEDICAMENT GROUP BY drug_name_generic HAVING COUNT(*) > 1;
