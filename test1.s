WITH cd AS (
SELECT
       x.name,
       x.physicaldisk
FROM v$cell_config c,
     XMLTABLE(
       '/cli-output/celldisk'
       PASSING XMLTYPE(c.confval)
       COLUMNS
         name VARCHAR2(100) PATH 'name',
         physicaldisk VARCHAR2(100) PATH 'physicalDisk'
     ) x
WHERE c.conftype='CELLDISKS'
)
SELECT *
FROM cd
FETCH FIRST 20 ROWS ONLY;



WITH pd AS (
SELECT
       x.id,
       x.name
FROM v$cell_config c,
     XMLTABLE(
       '/cli-output/physicaldisk'
       PASSING XMLTYPE(c.confval)
       COLUMNS
         id   VARCHAR2(100) PATH 'id',
         name VARCHAR2(100) PATH 'name'
     ) x
WHERE c.conftype='PHYSICALDISKS'
)
SELECT *
FROM pd
FETCH FIRST 20 ROWS ONLY;




SELECT *
FROM (
  SELECT x.*
  FROM v$cell_config c,
       XMLTABLE(
         '/cli-output/physicaldisk'
         PASSING XMLTYPE(c.confval)
         COLUMNS
           name VARCHAR2(200) PATH 'name',
           status VARCHAR2(100) PATH 'status',
           disktype VARCHAR2(100) PATH 'diskType',
           slotnumber VARCHAR2(100) PATH 'slotNumber',
           physicalserial VARCHAR2(200) PATH 'physicalSerial',
           key500 VARCHAR2(200) PATH 'key_500'
       ) x
  WHERE c.conftype='PHYSICALDISKS'
)
FETCH FIRST 20 ROWS ONLY;