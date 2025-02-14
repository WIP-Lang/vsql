SELECT * FROM foo;
-- error 42P01: no such table: FOO

CREATE TABLE foo (a FLOAT);
INSERT INTO foo (a) VALUES (1.234);
SELECT * FROM foo;
-- msg: CREATE TABLE 1
-- msg: INSERT 1
-- A: 1.234

CREATE TABLE foo (a FLOAT);
CREATE TABLE "Foo" ("a" FLOAT);
INSERT INTO FOO (a) VALUES (1.234);
INSERT INTO "Foo" ("a") VALUES (4.56);
SELECT * FROM Foo;
SELECT * FROM "Foo";
-- msg: CREATE TABLE 1
-- msg: CREATE TABLE 1
-- msg: INSERT 1
-- msg: INSERT 1
-- A: 1.234
-- a: 4.56

SELECT *
FROM foo;
SELECT 'a';
-- error 42P01: no such table: FOO
-- COL1: a
