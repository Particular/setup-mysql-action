-- Runs as root inside the MySQL container once the server is ready.
-- Creates objects the CI validation steps rely on. The grants target the
-- action's default user (particular) so the connection-string tests can read
-- what this script writes. shim_test exists so the mysql CLI shim can be
-- exercised with a known password.

CREATE DATABASE IF NOT EXISTS init_test;

CREATE TABLE IF NOT EXISTS init_test.round_trip (
    Id INT AUTO_INCREMENT PRIMARY KEY,
    Value VARCHAR(100)
);

INSERT INTO init_test.round_trip (Value) VALUES ('from-init-script');

GRANT ALL PRIVILEGES ON init_test.* TO 'particular'@'%';

CREATE USER IF NOT EXISTS 'shim_test'@'%' IDENTIFIED BY 'shim_pass';
GRANT ALL PRIVILEGES ON init_test.* TO 'shim_test'@'%';
