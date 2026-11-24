-- Q10(a) Tables & Seed Data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id   SERIAL PRIMARY KEY,
    student_id       INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income   NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark     NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on     DATE NOT NULL,
    status           VARCHAR(12) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(12) NOT NULL,
    new_status     VARCHAR(12) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Q10(b) Function: fn_scholarship_eligible (age 18..25, income <= 3000, mark >= 70)
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INT,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- Q10(c) Procedure: pr_assess_application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(12);
    v_eligible BOOLEAN;
    v_next     VARCHAR(12);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed with status %', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
    v_next     := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
    SET status = v_next
    WHERE application_id = p_application_id;
END;
$$;

-- Q10(d) Trigger: AFTER UPDATE logs actual status changes
CREATE OR REPLACE FUNCTION fn_trg_applications_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_trg_applications_decision_audit();

-- Seed 3 students & 6 PENDING applications (qualifying, non-qualifying & boundaries)
INSERT INTO students (student_number, full_name) VALUES
    ('ST-01', 'Mumba Kaluba'),
    ('ST-02', 'Chanda Lombe'),
    ('ST-03', 'Mulenga Bwalya');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 10, 'PENDING'), -- Exact lower/upper boundaries: APPROVED
    (1, 25, 2500.00, 82.50, CURRENT_DATE - 8,  'PENDING'), -- Upper age boundary: APPROVED
    (2, 26, 2000.00, 85.00, CURRENT_DATE - 6,  'PENDING'), -- Over age limit: REJECTED
    (2, 20, 3500.00, 90.00, CURRENT_DATE - 5,  'PENDING'), -- Over income limit: REJECTED
    (3, 21, 1500.00, 69.99, CURRENT_DATE - 3,  'PENDING'), -- Below mark threshold: REJECTED
    (3, 22, 0.00,    100.00, CURRENT_DATE - 1, 'PENDING'); -- Zero income & max mark: APPROVED

-- Q10(e) View: v_approved_applicants (omits monthly_income)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- Q10(f) Composite Index & EXPLAIN
-- Supports filtering by status and date range on submitted_on
CREATE INDEX idx_applications_status_submitted_on ON applications (status, submitted_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;
-- Expected plan node: Index Scan using idx_applications_status_submitted_on on applications

-- Q10(g) Procedure & Scheduled Job (Monday 08:00)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'assess_pending_scholarships',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);