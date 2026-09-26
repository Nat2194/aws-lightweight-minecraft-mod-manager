output "minecraft_server_ip" {
  description = "Server Public IP"
  value       = aws_instance.mc_server.public_ip
}