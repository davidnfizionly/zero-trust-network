# Inspection routing. Every packet between the internet and the public subnets (the load balancer
# and the NAT gateway) goes through the firewall endpoint, in both directions:
#   inbound: internet gateway, edge route table, firewall endpoint, public subnet
#   outbound: public subnet, the two /1 routes, firewall endpoint, firewall subnet route table, internet gateway

resource "aws_subnet" "firewall" {
  vpc_id                  = data.aws_vpc.workload.id
  cidr_block              = var.firewall_subnet_cidr
  availability_zone       = local.firewall_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.workload_name}-firewall-${local.firewall_az}"
  }
}

resource "aws_route_table" "firewall" {
  vpc_id = data.aws_vpc.workload.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.workload.id
  }

  tags = {
    Name = "${var.workload_name}-firewall"
  }
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

locals {
  firewall_endpoint_id = one([
    for s in aws_networkfirewall_firewall.this.firewall_status[0].sync_states :
    s.attachment[0].endpoint_id if s.availability_zone == local.firewall_az
  ])
}

# Ingress routing: traffic entering through the internet gateway towards the public subnets
# is sent to the firewall first.
resource "aws_route_table" "edge" {
  vpc_id = data.aws_vpc.workload.id

  tags = {
    Name = "${var.workload_name}-igw-edge"
  }
}

resource "aws_route" "edge_to_firewall" {
  for_each = toset(local.public_cidrs)

  route_table_id         = aws_route_table.edge.id
  destination_cidr_block = each.value
  vpc_endpoint_id        = local.firewall_endpoint_id
}

resource "aws_route_table_association" "edge" {
  gateway_id     = data.aws_internet_gateway.workload.id
  route_table_id = aws_route_table.edge.id
}

# Return and egress routing. The VPC module owns the public 0.0.0.0/0 route to the internet
# gateway; the two /1 routes are more specific, so they win without editing that route (ADR-006).
resource "aws_route" "public_via_firewall" {
  for_each = toset(["0.0.0.0/1", "128.0.0.0/1"])

  route_table_id         = data.aws_route_table.public.id
  destination_cidr_block = each.value
  vpc_endpoint_id        = local.firewall_endpoint_id
}
