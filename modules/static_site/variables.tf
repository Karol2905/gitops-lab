variable "project_id" {
  type        = string
  description = "Proyecto de GCP del entorno (ya existe: lo crea el bootstrap)."
}

variable "location" {
  type        = string
  description = "Región del bucket, por ejemplo us-central1."
}

variable "prefix" {
  type        = string
  description = "Prefijo corto para el nombre del bucket."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.prefix))
    error_message = "El prefijo debe tener de 3 a 8 letras minúsculas o dígitos y empezar por letra."
  }
}

variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "El entorno debe ser dev o prod."
  }
}

variable "index_file" {
  type        = string
  description = "Ruta del archivo index.html que se publica."
}

variable "labels" {
  type        = map(string)
  description = "Etiquetas (labels) del bucket."

  validation {
    condition = alltrue([
      for k in ["owner", "environment", "course"] : can(var.labels[k])
    ])
    error_message = "Etiquetas obligatorias: owner, environment y course."
  }

  validation {
    condition = alltrue([
      for k, v in var.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "En GCP las etiquetas solo admiten minúsculas, dígitos, guion y guion bajo."
  }
}
