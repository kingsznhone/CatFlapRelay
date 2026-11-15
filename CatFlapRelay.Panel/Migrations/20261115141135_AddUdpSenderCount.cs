using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace CatFlapRelay.Panel.Migrations
{
    /// <inheritdoc />
    public partial class AddUdpSenderCount : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "UdpSenderCount",
                table: "Relays",
                type: "INTEGER",
                nullable: false,
                // Existing rows must get 1, not the CLR default 0: FlapRelayFactory.ValidateOption
                // rejects 0, so every relay saved before this upgrade would fail to load.
                defaultValue: 1);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "UdpSenderCount",
                table: "Relays");
        }
    }
}
