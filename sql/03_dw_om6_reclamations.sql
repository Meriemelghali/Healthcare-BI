-- =====================================================================
-- OM6 Réclamations : tables du DW (6 dimensions + 5 faits)
-- Adapté du script de Sami (Heathcare (1).txt)
--
-- Base cible : HealthcareDW   |   Schéma : dw
-- Ce script ne touche PAS à HealthcareDB (archive) ni au staging.
-- Il ne supprime que ses propres tables (schéma dw).
--
-- Retirés par rapport au script d'origine (remplacés par le staging) :
--   dbo.SA_RECLAMATIONS -> HealthcareDB_Staging.stg.RECLAMATIONS
--   dbo.ADMISSIONS, SERVICES, CALLOUT, PATIENTS -> stg.*
-- =====================================================================
USE HealthcareDW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
    EXEC('CREATE SCHEMA dw');
GO

-- ---------------------------------------------------------------------
-- Faits d'abord (ils référencent les dimensions) : on les supprime en premier
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS FACT_Reclamations_Periode;
DROP TABLE IF EXISTS FACT_Reclamations_LOS;
DROP TABLE IF EXISTS FACT_Reclamations_Services;
DROP TABLE IF EXISTS FACT_Reclamations_ICU;
DROP TABLE IF EXISTS FACT_Reclamations_Profil;
GO

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_Reclamation (
    Reclamation_Key          INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_ID           NVARCHAR(50),
    Complaint_Type           NVARCHAR(100),
    Status                   NVARCHAR(50),
    Resolution_Duration_Days FLOAT,
    Satisfaction_Impact      FLOAT
);

DROP TABLE IF EXISTS om6.DIM_Temps;
CREATE TABLE dw.dim_Temps (
    Temps_Key  INT IDENTITY(1,1) PRIMARY KEY,
    Periode    NVARCHAR(7),
    Annee      INT,
    Trimestre  INT,
    Mois       INT
);

DROP TABLE IF EXISTS om6.DIM_Patient;
CREATE TABLE dw.dim_Patient (
    Patient_Key    INT IDENTITY(1,1) PRIMARY KEY,
    subject_id     NVARCHAR(50),
    Gender         NVARCHAR(10),
    Insurance      NVARCHAR(100),
    Ethnicity      NVARCHAR(100),
    Admission_Type NVARCHAR(50)
);

DROP TABLE IF EXISTS om6.DIM_Service;
CREATE TABLE dw.dim_Service (
    Service_Key  INT IDENTITY(1,1) PRIMARY KEY,
    curr_service NVARCHAR(50),
    prev_service NVARCHAR(50)
);

DROP TABLE IF EXISTS om6.DIM_Admission;
CREATE TABLE dw.dim_Admission (
    Admission_Key  INT IDENTITY(1,1) PRIMARY KEY,
    hadm_id        VARCHAR(255),
    admittime      VARCHAR(255),
    dischtime      VARCHAR(255),
    Tranche_LOS    VARCHAR(50),
    Admission_Type VARCHAR(255),
    subject_id     VARCHAR(50)
);

DROP TABLE IF EXISTS om6.DIM_ICU;
CREATE TABLE dw.dim_ICU (
    ICU_Key         INT IDENTITY(1,1) PRIMARY KEY,
    hadm_id         NVARCHAR(255),
    Callout_Outcome NVARCHAR(255),
    Tranche_Delai   NVARCHAR(50),
    createtime      NVARCHAR(255),
    outcometime     NVARCHAR(255)
);
GO

-- ---------------------------------------------------------------------
-- TABLES DE FAITS
-- ---------------------------------------------------------------------
CREATE TABLE FACT_Reclamations_Periode (
    Fact_Key                  INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_FK            INT,
    Temps_FK                  INT,
    Nb_Reclamations           INT,
    Nb_Resolues               INT,
    Delai_Resolution_Moyen    FLOAT,
    Impact_Satisfaction_Moyen FLOAT
);

CREATE TABLE FACT_Reclamations_LOS (
    Fact_Key        INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_FK  INT,
    Admission_FK    INT,
    Patient_FK      INT,
    Nb_Reclamations INT,
    LOS_Moyen       FLOAT,
    Impact_Moyen    FLOAT
);

CREATE TABLE FACT_Reclamations_Services (
    Fact_Key        INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_FK  INT,
    Service_FK      INT,
    Admission_FK    INT,
    Nb_Reclamations INT,
    Nb_Resolues     INT,
    Delai_Moyen     FLOAT
);

CREATE TABLE FACT_Reclamations_ICU (
    Fact_Key               INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_FK         INT,
    ICU_FK                 INT,
    Admission_FK           INT,
    Nb_Reclamations        INT,
    Delai_ICU_Moyen        FLOAT,
    Delai_Resolution_Moyen FLOAT
);

CREATE TABLE FACT_Reclamations_Profil (
    Fact_Key        INT IDENTITY(1,1) PRIMARY KEY,
    Reclamation_FK  INT,
    Patient_FK      INT,
    Nb_Reclamations INT,
    Impact_Moyen    FLOAT,
    Delai_Moyen     FLOAT
);
GO

-- ---------------------------------------------------------------------
-- Journal de chargement (partagé par le groupe)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dw.ETL_Log') IS NULL AND EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
    CREATE TABLE dw.ETL_Log (
        Log_ID         INT IDENTITY(1,1) PRIMARY KEY,
        Package_Name   NVARCHAR(100),
        Statut         NVARCHAR(20),
        Message        NVARCHAR(500),
        Date_Execution DATETIME DEFAULT GETDATE()
    );
GO

-- Vérification : 6 dimensions + 5 faits attendus
SELECT TABLE_SCHEMA, TABLE_NAME
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'dw'
ORDER BY TABLE_NAME;
