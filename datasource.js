const { DataSource } = require("typeorm");
module.exports = new DataSource({
  type: "postgres",
  host: "db_kodus_postgres",
  port: 5432,
  username: process.env.API_PG_DB_USERNAME,
  password: process.env.API_PG_DB_PASSWORD,
  database: process.env.API_PG_DB_DATABASE,
  ssl: false,
  entities: ["./dist/modules/**/infra/typeorm/entities/*.js"],
  migrations: ["./dist/config/database/typeorm/migrations/*.js"]
});
