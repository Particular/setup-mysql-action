using MySqlConnector;
using NUnit.Framework;

[TestFixture]
public class ConnectionTests
{
    static string ConnectionString => Environment.GetEnvironmentVariable("MySQLConnectionString")
        ?? throw new InvalidOperationException("Environment variable 'MySQLConnectionString' not set.");

    [Test]
    public void Should_connect()
    {
        using var connection = new MySqlConnection(ConnectionString);
        connection.Open();

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1";
        Assert.That(Convert.ToInt32(command.ExecuteScalar()), Is.EqualTo(1));
    }

    [Test]
    public void Should_create_table_and_round_trip_data()
    {
        using var connection = new MySqlConnection(ConnectionString);
        connection.Open();

        using var create = connection.CreateCommand();
        create.CommandText = "CREATE TABLE IF NOT EXISTS round_trip (Id INT AUTO_INCREMENT PRIMARY KEY, Value VARCHAR(100))";
        create.ExecuteNonQuery();

        using var insert = connection.CreateCommand();
        insert.CommandText = "INSERT INTO round_trip (Value) VALUES (@value)";
        insert.Parameters.AddWithValue("@value", $"setup-mysql-action-{Guid.NewGuid():N}");
        insert.ExecuteNonQuery();

        using var select = connection.CreateCommand();
        select.CommandText = "SELECT COUNT(*) FROM round_trip";
        Assert.That(Convert.ToInt32(select.ExecuteScalar()), Is.GreaterThan(0));
    }

    [Test]
    public void Should_read_data_created_by_init_script()
    {
        using var connection = new MySqlConnection(ConnectionString);
        connection.Open();

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM init_test.round_trip";
        Assert.That(Convert.ToInt32(command.ExecuteScalar()), Is.GreaterThan(0));
    }
}
