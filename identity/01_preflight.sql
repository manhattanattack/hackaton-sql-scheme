-- Initial schema review AFTER backend creates Identity tables; read-only.
USE vacancy_aggregator;
SELECT c.TABLE_NAME,c.COLUMN_NAME,c.COLUMN_TYPE,c.CHARACTER_SET_NAME,
  c.COLLATION_NAME,c.IS_NULLABLE,t.ENGINE
FROM information_schema.COLUMNS c
JOIN information_schema.TABLES t ON t.TABLE_SCHEMA=c.TABLE_SCHEMA AND t.TABLE_NAME=c.TABLE_NAME
WHERE c.TABLE_SCHEMA=DATABASE()
  AND ((c.TABLE_NAME='AspNetUsers' AND c.COLUMN_NAME='Id')
    OR (c.TABLE_NAME='user_profiles' AND c.COLUMN_NAME='auth_subject'));

-- Must return zero rows before FK setup. Resolve accounts via backend UserManager.
SELECT p.id,p.auth_subject FROM user_profiles p
LEFT JOIN AspNetUsers u ON u.Id=p.auth_subject WHERE u.Id IS NULL;

-- Backend must configure UNIQUE, full-length NormalizedEmail index.
SELECT INDEX_NAME,NON_UNIQUE,COLUMN_NAME,SUB_PART,SEQ_IN_INDEX
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='AspNetUsers'
ORDER BY INDEX_NAME,SEQ_IN_INDEX;
