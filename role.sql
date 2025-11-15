SELECT 'SYS PRIV' AS type,
       sp.grantee,
       sp.privilege
FROM dba_sys_privs sp
WHERE sp.grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')

UNION ALL
SELECT 'ROLE',
       rp.grantee,
       rp.granted_role
FROM dba_role_privs rp
WHERE rp.grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')

UNION ALL
SELECT 'OBJ PRIV',
       tp.grantee,
       tp.owner || '.' || tp.table_name || ' - ' || tp.privilege
FROM dba_tab_privs tp
WHERE tp.grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')

ORDER BY grantee, type;