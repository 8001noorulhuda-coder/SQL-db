
PRAGMA foreign_keys = ON;

DROP VIEW  IF EXISTS appointment_bills;
DROP VIEW  IF EXISTS admission_stays;
DROP VIEW  IF EXISTS patient_ages;
DROP TABLE IF EXISTS prescriptions;
DROP TABLE IF EXISTS appointment_diagnoses;
DROP TABLE IF EXISTS admissions;
DROP TABLE IF EXISTS appointments;
DROP TABLE IF EXISTS patients;
DROP TABLE IF EXISTS doctors;
DROP TABLE IF EXISTS medications;
DROP TABLE IF EXISTS diagnoses;
DROP TABLE IF EXISTS departments;

-- Schema --

CREATE TABLE departments (
    department_id    INTEGER PRIMARY KEY,
    department_name  TEXT NOT NULL UNIQUE,
    main_ward        TEXT NOT NULL,                                    -- nominal
    bed_capacity     INTEGER NOT NULL CHECK (bed_capacity > 0)         -- ratio
);

CREATE TABLE doctors (
    doctor_id        INTEGER PRIMARY KEY,
    first_name       TEXT NOT NULL,
    last_name        TEXT NOT NULL,
    gender           TEXT NOT NULL CHECK (gender IN ('Male','Female')),
    department_id    INTEGER NOT NULL,
    seniority_level  TEXT NOT NULL
                     CHECK (seniority_level IN ('Junior Doctor','Registrar','Consultant','Senior Consultant')),  -- ordinal
    hire_date        TEXT NOT NULL,                                    -- interval
    consultation_fee REAL NOT NULL CHECK (consultation_fee > 0),       -- ratio
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

-- No address, phone number or national ID is stored (data minimisation).
CREATE TABLE patients (
    patient_id         INTEGER PRIMARY KEY,
    first_name         TEXT NOT NULL,
    last_name          TEXT NOT NULL,
    gender             TEXT NOT NULL CHECK (gender IN ('Male','Female','Other')),          -- nominal
    date_of_birth      TEXT NOT NULL,                                                      -- interval
    blood_group        TEXT NOT NULL
                       CHECK (blood_group IN ('O+','O-','A+','A-','B+','B-','AB+','AB-')), -- nominal
    city               TEXT NOT NULL,                                                      -- nominal
    insurance_type     TEXT NOT NULL
                       CHECK (insurance_type IN ('NHS','Private Insurance','Self-pay')),   -- nominal
    height_cm          REAL NOT NULL CHECK (height_cm BETWEEN 40 AND 230),                 -- ratio
    weight_kg          REAL NOT NULL CHECK (weight_kg BETWEEN 2 AND 300),                  -- ratio
    registration_date  TEXT NOT NULL                                                       -- interval
);

CREATE TABLE diagnoses (
    diagnosis_id    INTEGER PRIMARY KEY,
    icd_code        TEXT NOT NULL UNIQUE,
    diagnosis_name  TEXT NOT NULL,
    department_id   INTEGER NOT NULL,
    severity_level  TEXT NOT NULL CHECK (severity_level IN ('Mild','Moderate','Severe')),  -- ordinal
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

CREATE TABLE medications (
    medication_id    INTEGER PRIMARY KEY,
    medication_name  TEXT NOT NULL,
    drug_class       TEXT NOT NULL,                                    -- nominal
    department_id    INTEGER NOT NULL,
    unit_cost        REAL NOT NULL CHECK (unit_cost > 0),              -- ratio
    FOREIGN KEY (department_id) REFERENCES departments(department_id)
);

CREATE TABLE appointments (
    appointment_id      INTEGER PRIMARY KEY,
    patient_id          INTEGER NOT NULL,
    doctor_id           INTEGER NOT NULL,
    appointment_date    TEXT NOT NULL,                                 -- interval
    appointment_type    TEXT NOT NULL
                        CHECK (appointment_type IN ('Check-up','Follow-up','Emergency','Referral','Procedure')),
    triage_level        TEXT NOT NULL CHECK (triage_level IN ('Low','Medium','High','Critical')),  -- ordinal
    status              TEXT NOT NULL CHECK (status IN ('Completed','Cancelled','No-show')),
    wait_minutes        INTEGER CHECK (wait_minutes >= 0),             -- ratio
    duration_minutes    INTEGER CHECK (duration_minutes > 0),          -- ratio
    satisfaction_score  INTEGER CHECK (satisfaction_score BETWEEN 1 AND 5),   -- ordinal, NULL if no reply
    -- only completed visits have a wait, a duration or a survey answer
    CHECK (status = 'Completed'
           OR (wait_minutes IS NULL AND duration_minutes IS NULL AND satisfaction_score IS NULL)),
    FOREIGN KEY (patient_id) REFERENCES patients(patient_id),
    FOREIGN KEY (doctor_id)  REFERENCES doctors(doctor_id)
);

-- Only some visits lead to an admission, so this is a separate 0-or-1 table (UNIQUE appointment_id).
CREATE TABLE admissions (
    admission_id           INTEGER PRIMARY KEY,
    appointment_id         INTEGER NOT NULL UNIQUE,
    ward                   TEXT NOT NULL,                              -- nominal
    admission_date         TEXT NOT NULL,                              -- interval
    discharge_date         TEXT NOT NULL,                              -- interval
    discharge_destination  TEXT NOT NULL
                           CHECK (discharge_destination IN ('Home','Transferred to Another Hospital','Rehabilitation Unit','Care Home')),
    CHECK (discharge_date >= admission_date),
    FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id)
);

-- Compound key: each diagnosis is recorded once per appointment (many-to-many).
CREATE TABLE appointment_diagnoses (
    appointment_id  INTEGER NOT NULL,
    diagnosis_id    INTEGER NOT NULL,
    is_primary      INTEGER NOT NULL CHECK (is_primary IN (0,1)),
    PRIMARY KEY (appointment_id, diagnosis_id),
    FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id),
    FOREIGN KEY (diagnosis_id)   REFERENCES diagnoses(diagnosis_id)
);

-- Compound key: each medication is prescribed once per appointment (many-to-many).
CREATE TABLE prescriptions (
    appointment_id  INTEGER NOT NULL,
    medication_id   INTEGER NOT NULL,
    quantity        INTEGER NOT NULL CHECK (quantity BETWEEN 1 AND 10),       -- packs, ratio
    duration_days   INTEGER NOT NULL CHECK (duration_days > 0),               -- ratio
    frequency       TEXT NOT NULL
                    CHECK (frequency IN ('Once daily','Twice daily','Three times daily','As needed')),  -- nominal
    PRIMARY KEY (appointment_id, medication_id),
    FOREIGN KEY (appointment_id) REFERENCES appointments(appointment_id),
    FOREIGN KEY (medication_id)  REFERENCES medications(medication_id)
);

CREATE INDEX idx_doctors_dept        ON doctors(department_id);
CREATE INDEX idx_appts_patient       ON appointments(patient_id);
CREATE INDEX idx_appts_doctor        ON appointments(doctor_id);
CREATE INDEX idx_appts_date          ON appointments(appointment_date);
CREATE INDEX idx_apptdx_diagnosis    ON appointment_diagnoses(diagnosis_id);
CREATE INDEX idx_rx_medication       ON prescriptions(medication_id);
CREATE INDEX idx_diagnoses_dept      ON diagnoses(department_id);
CREATE INDEX idx_medications_dept    ON medications(department_id);

-- Calculated values are views, not stored columns, so they cannot go out of sync.
CREATE VIEW patient_ages AS
SELECT patient_id,
       CAST((julianday('2026-10-31') - julianday(date_of_birth)) / 365.25 AS INTEGER) AS age_years
FROM patients;

CREATE VIEW admission_stays AS
SELECT admission_id, appointment_id, ward,
       CAST(julianday(discharge_date) - julianday(admission_date) AS INTEGER) AS length_of_stay_days
FROM admissions;

CREATE VIEW appointment_bills AS
SELECT t.appointment_id, t.consultation_fee, t.medication_cost,
       ROUND(t.consultation_fee + t.medication_cost, 2) AS total_bill
FROM (SELECT a.appointment_id,
             CASE WHEN a.status = 'Completed' THEN d.consultation_fee ELSE 0 END AS consultation_fee,
             ROUND(COALESCE((SELECT SUM(p.quantity * m.unit_cost)
                             FROM prescriptions p JOIN medications m ON m.medication_id = p.medication_id
                             WHERE p.appointment_id = a.appointment_id), 0), 2) AS medication_cost
      FROM appointments a JOIN doctors d ON d.doctor_id = a.doctor_id) t;

-- Fixed reference data (IDs run 1..10 for departments, 1..40 for diagnoses and medications,
-- four per department in department order) -----------

INSERT INTO departments (department_name, main_ward, bed_capacity) VALUES
 ('Cardiology','Cardiac Unit',32),('Neurology','Neurology Ward',28),
 ('Orthopaedics','Orthopaedic Ward',40),('Paediatrics','Paediatric Ward',30),
 ('Emergency Medicine','Acute Medical Unit',36),('General Medicine','General Ward',50),
 ('Dermatology','Day Surgery Unit',12),('Oncology','Oncology Ward',26),
 ('Respiratory Medicine','Respiratory Ward',30),('Psychiatry','Psychiatric Unit',20);

-- The first diagnosis in each department is the most common one (see the skewed picks below)
INSERT INTO diagnoses (icd_code, diagnosis_name, department_id, severity_level) VALUES
 ('I10','Essential hypertension',1,'Moderate'),('I25','Chronic ischaemic heart disease',1,'Severe'),
 ('I48','Atrial fibrillation',1,'Moderate'),('I50','Heart failure',1,'Severe'),
 ('G43','Migraine',2,'Mild'),('G40','Epilepsy',2,'Moderate'),
 ('G20','Parkinson disease',2,'Severe'),('I63','Cerebral infarction',2,'Severe'),
 ('M54','Back pain',3,'Mild'),('M17','Osteoarthritis of the knee',3,'Moderate'),
 ('S52','Fracture of forearm',3,'Moderate'),('M81','Osteoporosis',3,'Mild'),
 ('J06','Acute upper respiratory infection',4,'Mild'),('R50','Fever of unknown origin',4,'Mild'),
 ('A09','Infectious gastroenteritis',4,'Mild'),('H66','Otitis media',4,'Mild'),
 ('R07','Chest pain',5,'Moderate'),('T14','Injury, unspecified',5,'Mild'),
 ('S06','Intracranial injury',5,'Severe'),('K35','Acute appendicitis',5,'Severe'),
 ('E11','Type 2 diabetes mellitus',6,'Moderate'),('E78','Hyperlipidaemia',6,'Mild'),
 ('N39','Urinary tract infection',6,'Mild'),('B34','Viral infection, unspecified',6,'Mild'),
 ('L20','Atopic dermatitis',7,'Mild'),('L70','Acne',7,'Mild'),
 ('L40','Psoriasis',7,'Moderate'),('L50','Urticaria',7,'Mild'),
 ('C50','Breast cancer',8,'Severe'),('C34','Lung cancer',8,'Severe'),
 ('C18','Colon cancer',8,'Severe'),('C61','Prostate cancer',8,'Severe'),
 ('J45','Asthma',9,'Moderate'),('J44','Chronic obstructive pulmonary disease',9,'Severe'),
 ('J30','Allergic rhinitis',9,'Mild'),('J18','Pneumonia',9,'Severe'),
 ('F32','Depressive episode',10,'Moderate'),('F41','Anxiety disorder',10,'Mild'),
 ('F31','Bipolar disorder',10,'Moderate'),('F20','Schizophrenia',10,'Severe');

-- Medication j in a department is the usual treatment for diagnosis j in the same department
INSERT INTO medications (medication_name, drug_class, department_id, unit_cost) VALUES
 ('Ramipril','ACE inhibitor',1,3.50),('Atorvastatin','Statin',1,4.20),
 ('Warfarin','Anticoagulant',1,5.00),('Bisoprolol','Beta blocker',1,3.80),
 ('Sumatriptan','Triptan',2,12.50),('Levetiracetam','Anticonvulsant',2,18.00),
 ('Levodopa','Dopaminergic',2,22.00),('Clopidogrel','Antiplatelet',2,6.50),
 ('Ibuprofen','NSAID',3,2.50),('Co-codamol','Opioid analgesic',3,4.00),
 ('Paracetamol','Analgesic',3,1.80),('Alendronic Acid','Bisphosphonate',3,7.50),
 ('Paracetamol Suspension','Analgesic',4,3.20),('Ibuprofen Suspension','NSAID',4,3.90),
 ('Oral Rehydration Salts','Rehydration',4,4.50),('Amoxicillin','Antibiotic',4,5.50),
 ('GTN Spray','Nitrate',5,6.00),('Morphine Sulfate','Opioid analgesic',5,14.00),
 ('Ondansetron','Antiemetic',5,9.00),('Cefuroxime','Antibiotic',5,11.00),
 ('Metformin','Antidiabetic',6,3.00),('Simvastatin','Statin',6,3.50),
 ('Trimethoprim','Antibiotic',6,4.50),('Cough Linctus','Cough suppressant',6,4.00),
 ('Hydrocortisone Cream','Topical steroid',7,3.50),('Isotretinoin','Retinoid',7,35.00),
 ('Calcipotriol','Vitamin D analogue',7,16.00),('Cetirizine','Antihistamine',7,2.80),
 ('Tamoxifen','Hormone therapy',8,22.00),('Cisplatin','Chemotherapy',8,85.00),
 ('Capecitabine','Chemotherapy',8,120.00),('Bicalutamide','Hormone therapy',8,45.00),
 ('Salbutamol','Bronchodilator',9,4.50),('Tiotropium','Bronchodilator',9,38.00),
 ('Beclometasone Nasal Spray','Corticosteroid',9,9.50),('Doxycycline','Antibiotic',9,5.00),
 ('Sertraline','SSRI',10,5.50),('Diazepam','Benzodiazepine',10,4.00),
 ('Lithium','Mood stabiliser',10,13.00),('Olanzapine','Antipsychotic',10,18.00);

-- Lookup tables used only to build the data --

CREATE TEMP TABLE first_names (id INTEGER PRIMARY KEY, name TEXT, gender TEXT);
INSERT INTO first_names (name, gender) VALUES
 ('James','Male'),('Olivia','Female'),('Mohammed','Male'),('Amelia','Female'),('Oliver','Male'),
 ('Fatima','Female'),('Noah','Male'),('Priya','Female'),('Harry','Male'),('Sophia','Female'),
 ('Ali','Male'),('Emily','Female'),('George','Male'),('Aisha','Female'),('Jack','Male'),
 ('Chloe','Female'),('Daniel','Male'),('Zara','Female'),('Liam','Male'),('Hannah','Female'),
 ('Thomas','Male'),('Grace','Female'),('Arthur','Male'),('Ruby','Female'),('Samuel','Male'),
 ('Isla','Female'),('Hassan','Male'),('Maryam','Female'),('Ethan','Male'),('Lily','Female');

CREATE TEMP TABLE last_names (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO last_names (name) VALUES
 ('Smith'),('Jones'),('Khan'),('Taylor'),('Brown'),('Patel'),('Wilson'),('Evans'),('Ahmed'),('Thomas'),
 ('Roberts'),('Walker'),('Wright'),('Hussain'),('Green'),('Hall'),('Clarke'),('Singh'),('Lewis'),('Murphy'),
 ('Davies'),('Johnson'),('Shah'),('Begum'),('Cooper'),('Morgan'),('Bell'),('Mahmood'),('Turner'),('Hughes');

-- cumulative weights out of 100
CREATE TEMP TABLE cities (city TEXT, cum_weight INTEGER);
INSERT INTO cities VALUES
 ('London',22),('Manchester',32),('Birmingham',42),('Leeds',50),('Glasgow',58),
 ('Liverpool',66),('Bristol',73),('Sheffield',79),('Edinburgh',85),('Cardiff',90),
 ('Belfast',95),('Newcastle',100);

-- approximate UK blood group frequencies
CREATE TEMP TABLE blood_groups (blood_group TEXT, cum_weight INTEGER);
INSERT INTO blood_groups VALUES
 ('O+',36),('A+',66),('B+',74),('AB+',76),('O-',89),('A-',97),('B-',99),('AB-',100);

-- Which department a non-emergency visit goes to depends on the patient's age group
CREATE TEMP TABLE dept_weights (age_group TEXT, department_id INTEGER, cum_weight INTEGER);
INSERT INTO dept_weights VALUES
 ('adult',1,14),('adult',2,24),('adult',3,38),('adult',6,65),('adult',7,73),
 ('adult',8,81),('adult',9,92),('adult',10,100),
 ('child',4,50),('child',6,64),('child',7,74),('child',9,86),('child',3,94),('child',2,100);

CREATE TEMP TABLE slots (slot INTEGER);
INSERT INTO slots VALUES (1),(2),(3);

-- Doctors (60, six per department) --

CREATE TEMP TABLE stg_doctors AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60)
SELECT n,
       abs(random() % 30) + 1 AS fn_id,
       abs(random() % 30) + 1 AS ln_id,
       abs(random() % 100)    AS sen_r,
       abs(random() % 1000000) / 1000000.0 AS hire_r,
       abs(random() % 21)     AS fee_r
FROM seq;

-- Senior doctors were hired earlier and charge higher fees
WITH x AS (
  SELECT s.*,
         CASE WHEN sen_r < 35 THEN 'Junior Doctor' WHEN sen_r < 65 THEN 'Registrar'
              WHEN sen_r < 90 THEN 'Consultant' ELSE 'Senior Consultant' END AS sen
  FROM stg_doctors s)
INSERT INTO doctors (doctor_id, first_name, last_name, gender, department_id, seniority_level, hire_date, consultation_fee)
SELECT x.n, f.name, l.name, f.gender,
       (x.n - 1) % 10 + 1,
       x.sen,
       date('2006-01-01', '+' || CASE x.sen
              WHEN 'Junior Doctor' THEN 6000 + CAST(x.hire_r * 1200 AS INT)
              WHEN 'Registrar'     THEN 4500 + CAST(x.hire_r * 1800 AS INT)
              WHEN 'Consultant'    THEN 2500 + CAST(x.hire_r * 3000 AS INT)
              ELSE                      500 + CAST(x.hire_r * 3500 AS INT) END || ' days'),
       CASE x.sen WHEN 'Junior Doctor' THEN 55 WHEN 'Registrar' THEN 85
                  WHEN 'Consultant' THEN 140 ELSE 210 END + x.fee_r
FROM x
JOIN first_names f ON f.id = x.fn_id
JOIN last_names  l ON l.id = x.ln_id;

-- Patients (1500) ------------------------------------------------------

CREATE TEMP TABLE stg_patients AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1500)
SELECT n,
       abs(random() % 30) + 1 AS fn_id,
       abs(random() % 30) + 1 AS ln_id,
       abs(random() % 100)    AS gender_r,
       abs(random() % 100)    AS grp_r,       -- age group: child / adult / older adult
       abs(random() % 1000)   AS age_r,
       abs(random() % 365)    AS days_r,
       abs(random() % 100)    AS bg_r,
       abs(random() % 100)    AS city_r,
       abs(random() % 100)    AS ins_r,
       abs(random() % 31)     AS h_r,
       abs(random() % 6)      AS b1,          -- three draws added together give a bell-shaped BMI
       abs(random() % 6)      AS b2,
       abs(random() % 6)      AS b3,
       abs(random() % 1000000) / 1000000.0 AS reg_r
FROM seq;

-- 15% children, 50% adults 16-59, 35% aged 60+ (hospitals see many older patients).
-- Height depends on age and gender; weight is worked out from a BMI so the two stay plausible.
WITH base AS (
  SELECT s.n, f.name AS fn, l.name AS ln, f.gender AS fg, s.gender_r, s.bg_r, s.city_r, s.ins_r,
         s.b1, s.b2, s.b3, s.reg_r,
         CASE WHEN s.grp_r < 15 THEN s.age_r % 16
              WHEN s.grp_r < 65 THEN 16 + s.age_r % 44
              ELSE 60 + s.age_r % 36 END AS age_years,
         s.days_r, s.h_r
  FROM stg_patients s
  JOIN first_names f ON f.id = s.fn_id
  JOIN last_names  l ON l.id = s.ln_id),
base2 AS (
  SELECT base.*,
         date('2026-10-31', '-' || (age_years * 365 + days_r) || ' days') AS dob,
         CASE WHEN age_years < 16 THEN 50 + age_years * 7 + h_r % 10
              ELSE 150 + (CASE WHEN fg = 'Male' THEN 10 ELSE 0 END) + h_r END AS height
  FROM base)
INSERT INTO patients (patient_id, first_name, last_name, gender, date_of_birth, blood_group, city,
                      insurance_type, height_cm, weight_kg, registration_date)
SELECT b.n, b.fn, b.ln,
       CASE WHEN b.gender_r < 99 THEN b.fg ELSE 'Other' END,
       b.dob,
       (SELECT blood_group FROM blood_groups WHERE cum_weight > b.bg_r ORDER BY cum_weight LIMIT 1),
       (SELECT city FROM cities WHERE cum_weight > b.city_r ORDER BY cum_weight LIMIT 1),
       CASE WHEN b.ins_r < 82 THEN 'NHS' WHEN b.ins_r < 96 THEN 'Private Insurance' ELSE 'Self-pay' END,
       b.height,
       ROUND((CASE WHEN b.age_years < 16 THEN 14 + (b.b1 + b.b2 + b.b3) / 3
                   ELSE 17 + b.b1 + b.b2 + b.b3 END) * (b.height / 100.0) * (b.height / 100.0), 1),
       date(max(b.dob, '2018-01-01'),
            '+' || CAST(b.reg_r * (julianday('2026-10-31') - julianday(max(b.dob, '2018-01-01'))) AS INT) || ' days')
FROM base2 b;

-- Appointments (5000) --

CREATE TEMP TABLE stg_appointments AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000)
SELECT n,
       abs(random() % 1000000) / 1000000.0 AS cust_r,
       abs(random() % 1000000) / 1000000.0 AS date_r,
       abs(random() % 100) AS type_r,
       abs(random() % 100) AS dept_r,
       abs(random() % 6)   AS doc_k,
       abs(random() % 100) AS triage_r,
       abs(random() % 100) AS status_r,
       abs(random() % 121) AS wait_r,
       abs(random() % 91)  AS dur_r
FROM seq;

-- Each visit is for a patient (mildly skewed so some patients visit more), goes to a department
-- that suits the patient's age (children see Paediatrics, adults never do) and to one of that
-- department's six doctors. A visit is never dated before the patient registered or the doctor was hired.
WITH
b1 AS (
  SELECT s.*, p.patient_id, p.registration_date AS reg,
         CASE WHEN s.type_r < 30 THEN 'Check-up' WHEN s.type_r < 65 THEN 'Follow-up'
              WHEN s.type_r < 77 THEN 'Emergency' WHEN s.type_r < 90 THEN 'Referral'
              ELSE 'Procedure' END AS appt_type,
         CASE WHEN p.date_of_birth > '2010-10-31' THEN 'child' ELSE 'adult' END AS age_group
  FROM stg_appointments s
  JOIN patients p ON p.patient_id = 1 + CAST(((s.cust_r + s.cust_r * s.cust_r) / 2.0) * 1500 AS INT)),
b2 AS (
  SELECT b1.*,
         CASE WHEN b1.appt_type = 'Emergency' THEN 5
              ELSE (SELECT w.department_id FROM dept_weights w
                    WHERE w.age_group = b1.age_group AND w.cum_weight > b1.dept_r
                    ORDER BY w.cum_weight LIMIT 1) END AS dept
  FROM b1),
b3 AS (
  SELECT b2.*, d.doctor_id, max(b2.reg, d.hire_date) AS start_date
  FROM b2 JOIN doctors d ON d.doctor_id = b2.dept + 10 * b2.doc_k),
b4 AS (
  SELECT b3.*,
         CASE WHEN status_r < 82 THEN 'Completed' WHEN status_r < 92 THEN 'Cancelled' ELSE 'No-show' END AS visit_status,
         CASE WHEN appt_type = 'Emergency'
              THEN CASE WHEN triage_r < 10 THEN 'Low' WHEN triage_r < 35 THEN 'Medium'
                        WHEN triage_r < 75 THEN 'High' ELSE 'Critical' END
              ELSE CASE WHEN triage_r < 55 THEN 'Low' WHEN triage_r < 85 THEN 'Medium'
                        WHEN triage_r < 97 THEN 'High' ELSE 'Critical' END END AS triage
  FROM b3)
INSERT INTO appointments (patient_id, doctor_id, appointment_date, appointment_type, triage_level, status,
                          wait_minutes, duration_minutes)
SELECT patient_id, doctor_id,
       date(start_date, '+' || CAST(date_r * (julianday('2026-10-31') - julianday(start_date)) AS INT) || ' days'),
       appt_type, triage, visit_status,
       -- urgent cases wait less
       CASE WHEN visit_status <> 'Completed' THEN NULL
            ELSE CASE triage WHEN 'Critical' THEN wait_r % 6
                             WHEN 'High'     THEN wait_r % 21
                             WHEN 'Medium'   THEN 10 + wait_r % 51
                             ELSE                 20 + wait_r % 101 END END,
       CASE WHEN visit_status <> 'Completed' THEN NULL
            ELSE CASE appt_type WHEN 'Check-up'  THEN 15 + dur_r % 16
                                WHEN 'Follow-up' THEN 10 + dur_r % 11
                                WHEN 'Emergency' THEN 30 + dur_r % 91
                                WHEN 'Referral'  THEN 20 + dur_r % 21
                                ELSE                  45 + dur_r % 76 END END
FROM b4
ORDER BY 3;

-- Satisfaction: 30% never answer; long waits push scores down.
CREATE TEMP TABLE stg_sat AS
SELECT appointment_id, abs(random() % 100) AS skip_r, abs(random() % 100) AS sat_r
FROM appointments;

UPDATE appointments
SET satisfaction_score = (
    SELECT CASE WHEN s.skip_r < 30 THEN NULL
                WHEN s.sat_r - (CASE WHEN appointments.wait_minutes > 60 THEN 25
                                     WHEN appointments.wait_minutes > 30 THEN 10 ELSE 0 END) < 10 THEN 1
                WHEN s.sat_r - (CASE WHEN appointments.wait_minutes > 60 THEN 25
                                     WHEN appointments.wait_minutes > 30 THEN 10 ELSE 0 END) < 22 THEN 2
                WHEN s.sat_r - (CASE WHEN appointments.wait_minutes > 60 THEN 25
                                     WHEN appointments.wait_minutes > 30 THEN 10 ELSE 0 END) < 42 THEN 3
                WHEN s.sat_r - (CASE WHEN appointments.wait_minutes > 60 THEN 25
                                     WHEN appointments.wait_minutes > 30 THEN 10 ELSE 0 END) < 70 THEN 4
                ELSE 5 END
    FROM stg_sat s WHERE s.appointment_id = appointments.appointment_id)
WHERE status = 'Completed';

-- Diagnoses --------------------------------------------------------------
-- Completed visits get 1-3 diagnoses. The first comes from the doctor's own department (common
-- conditions more often). Extra ones are the same department, a deliberate "partner" condition
-- (hypertension + diabetes, heart disease + high cholesterol, heart failure + COPD,
-- depression + anxiety), or any diagnosis. The partner pairs give association rules something to find.

CREATE TEMP TABLE stg_dxn AS
SELECT a.appointment_id, d.department_id AS dept,
       abs(random() % 100) AS n_r,
       abs(random() % 1000000) / 1000000.0 AS p_r
FROM appointments a JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.status = 'Completed';

CREATE TEMP TABLE stg_dx AS
SELECT b.appointment_id, sl.slot, b.dept,
       (b.dept - 1) * 4 + 1 + CAST(b.p_r * b.p_r * 4 AS INT) AS first_dx,
       abs(random() % 100) AS mode_r,
       abs(random() % 1000000) / 1000000.0 AS e_r,
       abs(random() % 40)  AS any_r
FROM stg_dxn b
JOIN slots sl ON sl.slot <= CASE WHEN b.n_r < 70 THEN 1 WHEN b.n_r < 92 THEN 2 ELSE 3 END;

WITH x AS (
  SELECT appointment_id, slot,
         CASE WHEN slot = 1 THEN first_dx
              WHEN mode_r < 35 THEN (dept - 1) * 4 + 1 + CAST(e_r * e_r * 4 AS INT)
              WHEN mode_r < 65 THEN CASE first_dx
                     WHEN 1 THEN 21 WHEN 21 THEN 1
                     WHEN 2 THEN 22 WHEN 22 THEN 2
                     WHEN 4 THEN 34 WHEN 34 THEN 4
                     WHEN 37 THEN 38 WHEN 38 THEN 37
                     ELSE 1 + any_r END
              ELSE 1 + any_r END AS dx
  FROM stg_dx)
-- OR IGNORE: if an extra diagnosis repeats one already recorded for the visit, the compound key rejects it
INSERT OR IGNORE INTO appointment_diagnoses (appointment_id, diagnosis_id, is_primary)
SELECT appointment_id, dx, CASE WHEN slot = 1 THEN 1 ELSE 0 END
FROM x
ORDER BY slot;

-- Prescriptions ----------------------------------------------------------
-- 75% of diagnoses lead to a prescription; 60% of those use the diagnosis's usual medication,
-- otherwise another medication from the same department.

CREATE TEMP TABLE stg_rx AS
SELECT appointment_id, diagnosis_id,
       abs(random() % 100) AS rx_r,
       abs(random() % 100) AS match_r,
       abs(random() % 4)   AS alt_r,
       abs(random() % 100) AS freq_r,
       abs(random() % 100) AS dur_r,
       abs(random() % 3)   AS qty_r
FROM appointment_diagnoses;

INSERT OR IGNORE INTO prescriptions (appointment_id, medication_id, quantity, duration_days, frequency)
SELECT appointment_id,
       ((diagnosis_id - 1) / 4) * 4 + 1 + CASE WHEN match_r < 60 THEN (diagnosis_id - 1) % 4 ELSE alt_r END,
       1 + qty_r,
       CASE WHEN dur_r < 40 THEN 7 WHEN dur_r < 70 THEN 14 WHEN dur_r < 90 THEN 28 ELSE 56 END,
       CASE WHEN freq_r < 35 THEN 'Once daily' WHEN freq_r < 70 THEN 'Twice daily'
            WHEN freq_r < 85 THEN 'Three times daily' ELSE 'As needed' END
FROM stg_rx
WHERE rx_r < 75;

-- Admissions -------------------------------------------------------------
-- Only completed High or Critical visits can lead to an admission. Critical cases may go to
-- intensive care and stay longer.

CREATE TEMP TABLE stg_adm AS
SELECT appointment_id,
       abs(random() % 100) AS adm_r, abs(random() % 100) AS icu_r,
       abs(random() % 100) AS los_r, abs(random() % 100) AS dest_r
FROM appointments
WHERE status = 'Completed' AND triage_level IN ('High','Critical');

INSERT INTO admissions (appointment_id, ward, admission_date, discharge_date, discharge_destination)
SELECT a.appointment_id,
       CASE WHEN a.triage_level = 'Critical' AND s.icu_r < 50 THEN 'Intensive Care Unit' ELSE dep.main_ward END,
       a.appointment_date,
       min(date(a.appointment_date,
                '+' || CASE a.triage_level WHEN 'Critical' THEN 3 + s.los_r % 15 ELSE 1 + s.los_r % 8 END || ' days'),
           '2026-10-31'),
       CASE WHEN s.dest_r < 78 THEN 'Home' WHEN s.dest_r < 90 THEN 'Transferred to Another Hospital'
            WHEN s.dest_r < 97 THEN 'Rehabilitation Unit' ELSE 'Care Home' END
FROM stg_adm s
JOIN appointments a ON a.appointment_id = s.appointment_id
JOIN doctors      d ON d.doctor_id      = a.doctor_id
JOIN departments dep ON dep.department_id = d.department_id
WHERE s.adm_r < CASE a.triage_level WHEN 'Critical' THEN 85 ELSE 45 END
ORDER BY a.appointment_date;

DROP TABLE stg_doctors;  DROP TABLE stg_patients; DROP TABLE stg_appointments; DROP TABLE stg_sat;
DROP TABLE stg_dxn;      DROP TABLE stg_dx;       DROP TABLE stg_rx;           DROP TABLE stg_adm;
DROP TABLE first_names;  DROP TABLE last_names;   DROP TABLE cities;          DROP TABLE blood_groups;
DROP TABLE dept_weights; DROP TABLE slots;

-- Checks (uncomment one at a time) --
-- SELECT 'patients', COUNT(*) FROM patients UNION ALL SELECT 'appointments', COUNT(*) FROM appointments
--   UNION ALL SELECT 'appointment_diagnoses', COUNT(*) FROM appointment_diagnoses
--   UNION ALL SELECT 'prescriptions', COUNT(*) FROM prescriptions UNION ALL SELECT 'admissions', COUNT(*) FROM admissions;
-- PRAGMA foreign_key_check;
-- SELECT dep.department_name, COUNT(*) AS visits FROM appointments a JOIN doctors d USING (doctor_id)
--   JOIN departments dep USING (department_id) GROUP BY 1 ORDER BY visits DESC;
-- SELECT a.diagnosis_id, b.diagnosis_id, COUNT(*) AS together FROM appointment_diagnoses a
--   JOIN appointment_diagnoses b ON a.appointment_id = b.appointment_id AND a.diagnosis_id < b.diagnosis_id
--   GROUP BY 1, 2 ORDER BY together DESC LIMIT 10;