SELECT 'SYS PRIV' AS type,
       grantee,
       privilege
FROM dba_sys_privs
UNION ALL
SELECT 'ROLE', grantee, granted_role
FROM dba_role_privs
UNION ALL
SELECT 'OBJ PRIV',
       grantee,
       owner || '.' || table_name || ' - ' || privilege
FROM dba_tab_privs
ORDER BY grantee;