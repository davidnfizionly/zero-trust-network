terraform {
  backend "s3" {
    key = "baseline/cluster.tfstate"
  }
}
