# terraform-demo
Terraform Code to deploy a small sample infrastructure to GCP

inside the locals block the variable project must be changed to you GCP project's ID
inside the backend block change the name of the bucket according to you infrastructure (it must be created before running terraform) and eventually change the prefix path of the terraform.tfstate

To run this code a Service Account with the correct privileges (use Owner Role for a quick POC) and corrisponding key is required, download the key as json and use it by exporting the GOOGLE_APPLICATION_CREDENTIALS variable equal to the path to the credentials json file

