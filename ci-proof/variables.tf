variable "region" {
  description = "Region for the proof subnet."
  type        = string
  default     = "us-central1"
}

variable "subnet_cidr" {
  description = "Proof subnet range. Outside the landing zone's 10.x plan so it can never collide with a vended network."
  type        = string
  default     = "192.168.250.0/28"
}
