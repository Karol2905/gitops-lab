# Laboratorio 6: GitOps con GitHub, Terraform y Google Cloud

Versión GCP del repositorio plantilla del laboratorio (PEMU 2026, Escuela
Colombiana de Ingeniería Julio Garavito). Siga la guía `GUIA-GCP.md`; no suba
secretos.

- `modules/static_site/`   módulo: bucket de Cloud Storage público con `index.html`
- `envs/dev`, `envs/prod`  un entorno por carpeta, cada uno con su propio estado y proyecto
- `site/index.html`        la página que se publica
- `.github/workflows/`     terraform-plan, terraform-apply, drift y destroy
- `bootstrap/bootstrap.sh` preparación de GCP (se ejecuta una vez, a mano, en Cloud Shell)
