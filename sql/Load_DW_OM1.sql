/* =============================================================================
   Healthcare BI - Objectif métier 1 : Mortalité hospitalière
   Fait F1 = FACT_SEJOUR  (grain : 1 hospitalisation = 1 hadm_id)
   Base DW : HealthcareDW (schéma dwh)  |  Staging : HealthcareDB_Staging (schéma stg)

   Aucune nouvelle dimension : F1 utilise celles déjà chargées
   (DIM_PATIENT, DIM_SEJOUR, DIM_TEMPS).
   Répond aux 3 questions de la présentation :
     BI 1  taux de séjours se terminant par un décès  -> SUM(flag_deces) / SUM(nb_sejours)
     BI 2  mortalité par âge, sexe, type d'admission   -> DIM_PATIENT (age, gender), DIM_SEJOUR (admission_type)
     BI 3  mortalité selon une caractéristique de santé -> DIM_PATIENT (HadDiabetes, HadHeartAttack, ...)
   ============================================================================= */

USE HealthcareDW;
GO

/* ============================ 1. CRÉATION DE LA TABLE ====================== */
IF OBJECT_ID(N'dwh.FACT_SEJOUR') IS NOT NULL DROP TABLE dwh.FACT_SEJOUR;
GO
CREATE TABLE dwh.FACT_SEJOUR (
    fact_sejour_sk         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_sejour PRIMARY KEY,
    patient_sk             int NOT NULL CONSTRAINT fk_f1_patient REFERENCES dwh.DIM_PATIENT (patient_sk),
    sejour_sk              int NOT NULL CONSTRAINT fk_f1_sejour  REFERENCES dwh.DIM_SEJOUR (sejour_sk)
                                        CONSTRAINT uq_f1_sejour  UNIQUE,              -- 1 ligne par séjour
    date_admit_sk          int NOT NULL CONSTRAINT fk_f1_admit   REFERENCES dwh.DIM_TEMPS (date_sk),
    date_discharge_sk      int NOT NULL CONSTRAINT fk_f1_disch   REFERENCES dwh.DIM_TEMPS (date_sk),  -- -1 si inconnue
    los_jours              decimal(9,2) NULL,    -- dischtime - admittime, en jours
    los_heures             decimal(9,2) NULL,    -- idem en heures
    delai_urgences_heures  decimal(9,2) NULL,    -- edouttime - edregtime ; NULL si pas de passage aux urgences
    flag_deces             smallint     NULL,    -- hospital_expire_flag : 1 = décès pendant le séjour
    nb_sejours             int NOT NULL CONSTRAINT df_f1_nb DEFAULT 1,
    flag_readmission_30j   smallint     NOT NULL CONSTRAINT df_f1_readm DEFAULT 0   -- 1 = séjour admis <= 30 j après la sortie du séjour précédent du même patient
);
GO

/* ===================== 2. SOURCE DE DF_FACT_SEJOUR (OLE DB Source) =============
   Connexion : HealthcareDB_Staging, mode SQL command.
   Avant : Execute SQL Task  ->  TRUNCATE TABLE dwh.FACT_SEJOUR
   Après la source, 2 Recherches (Full cache, "Fail component", sortie avec correspondance) :
        subject_id -> DIM_PATIENT.patient_sk        hadm_id -> DIM_SEJOUR.sejour_sk
   Les dates sont déjà au format AAAAMMJJ : pas de Recherche, la base contrôle la clé.   */
SELECT  TRY_CONVERT(int, a.subject_id) AS subject_id,
        TRY_CONVERT(int, a.hadm_id)    AS hadm_id,
        CAST(CONVERT(char(8), TRY_CONVERT(date, c.adm), 112) AS int)                 AS date_admit_sk,
        ISNULL(CAST(CONVERT(char(8), TRY_CONVERT(date, c.disch), 112) AS int), -1)   AS date_discharge_sk,
        CAST(DATEDIFF(MINUTE, c.adm, c.disch) / 1440.0 AS decimal(9,2))              AS los_jours,
        CAST(DATEDIFF(MINUTE, c.adm, c.disch) / 60.0   AS decimal(9,2))              AS los_heures,
        CAST(DATEDIFF(MINUTE, c.edreg, c.edout) / 60.0 AS decimal(9,2))              AS delai_urgences_heures,
        TRY_CONVERT(smallint, TRY_CONVERT(float, a.hospital_expire_flag))            AS flag_deces,
        CAST(CASE WHEN pv.prev_disch IS NOT NULL
                   AND DATEDIFF(DAY, pv.prev_disch, c.adm) BETWEEN 0 AND 30
                  THEN 1 ELSE 0 END AS smallint)                                     AS flag_readmission_30j
FROM stg.ADMISSIONS a
CROSS APPLY (SELECT TRY_CONVERT(datetime2(0), a.admittime) AS adm,
                    TRY_CONVERT(datetime2(0), a.dischtime) AS disch,
                    TRY_CONVERT(datetime2(0), a.edregtime) AS edreg,
                    TRY_CONVERT(datetime2(0), a.edouttime) AS edout) c
OUTER APPLY (SELECT MAX(TRY_CONVERT(datetime2(0), p.dischtime)) AS prev_disch
             FROM stg.ADMISSIONS p
             WHERE p.subject_id = a.subject_id
               AND TRY_CONVERT(datetime2(0), p.admittime) < c.adm) pv
WHERE TRY_CONVERT(int, a.hadm_id) IS NOT NULL;
GO

/* ===================== 3. Destination : [dwh].[FACT_SEJOUR] ===================
   Mappings : patient_sk, sejour_sk, date_admit_sk, date_discharge_sk, los_jours, los_heures,
              delai_urgences_heures, flag_deces, flag_readmission_30j.
   Sans lien : fact_sejour_sk (identité) et nb_sejours (valeur par défaut 1).           */

/* ============================== 4. CONTRÔLES ================================ */
SELECT COUNT(*) AS nb_lignes                                     -- attendu : 129
FROM dwh.FACT_SEJOUR;

SELECT SUM(flag_deces) AS nb_deces,                              -- attendu : 40
       COUNT(*)        AS nb_sejours,                            -- attendu : 129
       CAST(100.0 * SUM(flag_deces) / COUNT(*) AS decimal(5,2)) AS taux_mortalite_pct    -- attendu : 31,01
FROM dwh.FACT_SEJOUR;

SELECT SUM(flag_readmission_30j)                                  AS readmissions_30j,    -- attendu : 11
       SUM(CASE WHEN delai_urgences_heures IS NULL THEN 1 ELSE 0 END) AS sans_urgences,   -- attendu : 37
       CAST(AVG(los_jours) AS decimal(5,1))                       AS duree_moyenne_jours  -- attendu : 9,3
FROM dwh.FACT_SEJOUR;

-- Exemple BI 2 : mortalité par type d'admission
SELECT s.admission_type, COUNT(*) AS sejours, SUM(f.flag_deces) AS deces,
       CAST(100.0 * SUM(f.flag_deces) / COUNT(*) AS decimal(5,1)) AS taux_pct
FROM dwh.FACT_SEJOUR f JOIN dwh.DIM_SEJOUR s ON s.sejour_sk = f.sejour_sk
GROUP BY s.admission_type;
