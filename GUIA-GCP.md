# PEMU 2026 – Laboratorio 6 (versión Google Cloud)

**GitOps con GitHub, Terraform y Google Cloud: infraestructura como código, pipelines y detección de deriva**

Esta guía sigue paso a paso el laboratorio original de Azure y cambia solo lo que depende de la nube. Los objetivos, el flujo GitOps, los cuatro workflows, los entornos de GitHub, el Ruleset, Checkov y el experimento de deriva son los mismos. Al final hay una tabla con cada pieza de Azure y su equivalente en GCP.

---

## Equivalencias Azure → GCP

| En la guía de Azure | En esta versión GCP |
|---|---|
| Suscripción *Azure for Students* | Cuenta de facturación con la prueba gratuita o créditos educativos de GCP |
| Grupos de recursos `rg-gitops-state`, `rg-gitops-dev`, `rg-gitops-prod` | Proyectos `gitops-state-<ID>`, `gitops-dev-<ID>`, `gitops-prod-<ID>` (`<ID>` = identificador numérico de su repositorio) |
| Azure Cloud Shell (`az`) | Google Cloud Shell (`gcloud`) |
| Región `eastus2` | Región `us-central1` |
| Identidad administrada `id-gitops-github` | Cuenta de servicio `sa-gitops-github` **sin claves** |
| Credenciales federadas (4 subjects) | *Workload Identity Federation*: pool `github`, proveedor OIDC `github-actions` y una vinculación `roles/iam.workloadIdentityUser` por subject |
| `Contributor` sobre los RG de dev y prod | `roles/storage.admin` solo en los proyectos de dev y prod |
| `Storage Blob Data Contributor` sobre el contenedor `tfstate` | `roles/storage.objectAdmin` solo sobre el bucket del estado |
| Backend `azurerm`, bloqueo por *lease* del blob | Backend `gcs`, bloqueo con un archivo `.tflock` (escritura condicional) |
| Cuenta de almacenamiento con sitio web estático (`$web`) | Bucket público de Cloud Storage con `index.html` |
| Variables `AZURE_*`, `TFSTATE_SA` | Variables `GCP_*`, `TFSTATE_BUCKET` |
| Etiquetas (*tags*) | Etiquetas (*labels*), solo minúsculas |

---

## Contexto: por qué GitHub gratuito, cuenta de servicio sin claves y OIDC

La restricción del curso es que **no se crean credenciales con secreto**. En GCP eso significa: **nunca se descarga una clave JSON de cuenta de servicio**. La cuenta de servicio `sa-gitops-github` existe solo para recibir permisos; GitHub Actions la *suplanta* (*impersonation*) con un token OIDC que dura minutos, a través de Workload Identity Federation. No hay contraseña que guardar, rotar ni filtrar.

> **Repositorio público significa cuidado.** Todo lo que se sube queda visible para cualquiera. Los identificadores de GCP (proveedor de WIF, email de la cuenta de servicio, ID de proyectos) van en *variables* de GitHub y no son secretos. El estado de Terraform vive en un bucket de GCP, no en Git. Si encuentra una clave JSON (`"type": "service_account"`, `"private_key"`), un token o una contraseña en un archivo, deténgase y bórrelo.

## Arquitectura del laboratorio

```
GitHub ─────────────────────────────────────────────────────────────────────
  Rama y PR → CI: fmt, validate, checkov, plan → revisión y merge a main
            → apply en dev (automático) → apply en prod (aprobación)
  Deriva: cron diario que abre un issue
                         │ token OIDC de GitHub (minutos, sin secretos)
                         ▼
Google Cloud ───────────────────────────────────────────────────────────────
  Proyecto gitops-state-<ID>: bucket <proyecto>-tfstate, cuenta de servicio,
                              pool y proveedor de Workload Identity
  Proyecto gitops-dev-<ID>:   bucket público con index.html
  Proyecto gitops-prod-<ID>:  bucket público con index.html
```

| Componente | Valor en este laboratorio |
|---|---|
| Repositorio | GitHub público con `modules/`, `envs/dev`, `envs/prod`, `site/` y `.github/workflows/` |
| Estado de Terraform | Bucket `gitops-state-<ID>-tfstate`, un prefijo por entorno (`dev/`, `prod/`). Bloqueo con `.tflock`, versionado activado, acceso público prohibido |
| Identidad | Cuenta de servicio `sa-gitops-github` + pool `github` con proveedor OIDC de GitHub. Cuatro subjects vinculados (pull request, rama `main`, entorno `dev`, entorno `prod`), en dos formatos |
| Permisos | `roles/storage.admin` solo en `gitops-dev-<ID>` y `gitops-prod-<ID>`; `roles/storage.objectAdmin` solo sobre el bucket del estado |
| Recursos gestionados | Por entorno: un bucket con acceso uniforme, lectura pública (`allUsers`) y un objeto `index.html` |
| Pipelines | `terraform-plan` (PR), `terraform-apply` (merge a `main`), `drift` (deriva) y `destroy` (manual) |
| Entornos de GitHub | `dev` sin aprobación y `prod` con aprobación manual |

Los tres proyectos se separan a propósito, igual que los tres grupos de recursos en Azure: el estado y la identidad no pueden borrarse por accidente cuando Terraform destruye un entorno, y la cuenta de servicio no tiene ningún permiso sobre el proyecto del estado más allá del bucket.

## Conceptos

Los conceptos de GitOps (push vs. pull), Terraform (estado, plan y bloqueo), entornos, aprobaciones y Rulesets son idénticos a la guía original. Lo que cambia es el mecanismo del estado y de OIDC:

| Mecanismo | Para qué sirve | En este laboratorio |
|---|---|---|
| Estado remoto | Una sola copia para el equipo y el pipeline | Bucket `...-tfstate` en Cloud Storage |
| Bloqueo | Evita dos `apply` simultáneos | El backend `gcs` crea `dev/default.tflock` con una escritura condicional (*solo si no existe*); automático |
| Versionado | Recuperar un estado anterior | Activado en el bootstrap |
| Acceso con identidad | Sin claves | La cuenta de servicio suplantada vía WIF; prevención de acceso público aplicada en el bucket |

### Autenticación sin secretos: OIDC + Workload Identity Federation

1. El job de GitHub Actions pide a GitHub un **token de identidad** firmado (JWT), gracias a `permissions: id-token: write`.
2. La acción `google-github-actions/auth` presenta ese JWT al **Security Token Service** de Google, indicando el proveedor de WIF.
3. El proveedor verifica el emisor (`https://token.actions.githubusercontent.com`) y la **condición de atributo**: `repository_owner_id` y `repository_id` deben ser los de *su* repositorio. Si no, rechaza el token.
4. Google comprueba que el `sub` del token (mapeado a `google.subject`) tenga `roles/iam.workloadIdentityUser` sobre `sa-gitops-github`. Esa vinculación por subject es el equivalente exacto de la credencial federada de Azure.
5. Se entrega un token de acceso de la cuenta de servicio, válido por una hora como máximo. Terraform lo usa; IAM decide qué puede hacer.

El *subject* es el candado. GitHub lo construye según el contexto y GCP lo compara **literalmente, distinguiendo mayúsculas y minúsculas**:

| Subject que emite GitHub | Cuándo |
|---|---|
| `repo:USUARIO@ID/REPO@ID:pull_request` | Workflows disparados por un Pull Request (el `plan`) |
| `repo:USUARIO@ID/REPO@ID:ref:refs/heads/main` | Ejecuciones sobre `main` sin entorno (el workflow `drift`) |
| `repo:USUARIO@ID/REPO@ID:environment:dev` | Jobs que declaran `environment: dev` |
| `repo:USUARIO@ID/REPO@ID:environment:prod` | Jobs que declaran `environment: prod` |

El bootstrap lee los identificadores de la API pública de GitHub y vincula también el formato antiguo (sin identificadores) por compatibilidad.

---

## Instrucciones detalladas

### Prerrequisitos

| Requisito | Detalle |
|---|---|
| Cuenta de GitHub | Gratuita. El repositorio se crea **público** y se llama `gitops-lab` |
| Cuenta de Google Cloud | Personal (gmail) con prueba gratuita o créditos educativos, y una **cuenta de facturación abierta**. Las cuentas institucionales pueden tener políticas que bloquean el sitio público (vea *Solución de problemas*) |
| Google Cloud Shell | Ícono `>_` arriba a la derecha de la consola. Trae `gcloud`, Terraform, Git y `jq` |
| Región | `us-central1` (entra en la capa gratuita de Cloud Storage) |
| Repositorio plantilla | Esta versión GCP de `gitops-lab-plantilla` |

> **Control de costos — configúrelo antes de empezar.** En la consola: *Facturación → Presupuestos y alertas → Crear presupuesto*. Fije **USD 5** con alerta al 80 %. Los recursos cuestan centavos, pero al terminar ejecute la sección *Limpieza de recursos*: el proyecto del estado también debe eliminarse.

### Parte 1. Preparar GCP (bootstrap)

Esta parte se hace **una sola vez y a mano**, con su propio usuario. Crea lo que el pipeline necesita antes de poder correr: los proyectos, el bucket del estado, la cuenta de servicio, Workload Identity Federation y los permisos.

1. Cree primero su repositorio a partir de la plantilla (**Use this template → Create a new repository**), nómbrelo `gitops-lab` y déjelo **Public**. Si no tiene el template, cree el repositorio vacío y suba el contenido del zip.
2. Abra Cloud Shell y verifique su cuenta y su facturación:
   ```bash
   gcloud auth list
   gcloud billing accounts list
   ```
3. Cree el script con el editor: `cloudshell edit bootstrap.sh` (o `nano bootstrap.sh`). Pegue el contenido de `bootstrap/bootstrap.sh`, cambie **solo** `GH_USER` y `GH_REPO` y guarde.
4. Ejecute `bash bootstrap.sh`. Tarda unos minutos. Si `gcloud` pide autorizar Cloud Shell, acepte.

Al terminar, el script imprime **seis valores**. Cópielos: los necesita en la Parte 2.

> **¿No puede crear proyectos?** Algunas cuentas de prueba tienen pocos proyectos con facturación, y algunas organizaciones prohíben crearlos. En ese caso escriba el ID de un proyecto existente en `PROJECT_STATE`, `PROJECT_DEV` y `PROJECT_PROD` (puede ser el mismo en las tres) y vuelva a ejecutar. Funciona igual, pero pierde el aislamiento entre entornos: menciónelo en la Pregunta 1.

> **Mayúsculas y minúsculas.** `GH_USER` y `GH_REPO` deben coincidir con la URL de su repositorio, que debe existir y ser público. Si el subject no coincide, el job falla con `Permission 'iam.serviceAccounts.getAccessToken' denied`.

Revise lo que creó el script (reemplace `<ID>` por el identificador de su repositorio, visible en los nombres de proyecto que imprimió el script):

```bash
STATE=gitops-state-<ID>
SA=sa-gitops-github@$STATE.iam.gserviceaccount.com

# Proveedor OIDC: condición de atributo y mapeo
gcloud iam workload-identity-pools providers describe github-actions \
  --project=$STATE --location=global --workload-identity-pool=github \
  --format="yaml(attributeCondition,attributeMapping,oidc.issuerUri)"

# Los subjects que pueden suplantar la cuenta de servicio
gcloud iam service-accounts get-iam-policy $SA --project=$STATE \
  --format=json | jq -r '.bindings[].members[]'

# Los permisos de la cuenta de servicio
for p in gitops-dev-<ID> gitops-prod-<ID>; do
  gcloud projects get-iam-policy $p --flatten="bindings[].members" \
    --filter="bindings.members:$SA" --format="table(bindings.role)"
done
gcloud storage buckets get-iam-policy gs://$STATE-tfstate

# Confirme que la cuenta de servicio NO tiene claves descargables
gcloud iam service-accounts keys list --iam-account=$SA --managed-by=user
```

> **Pregunta 1.** Un atacante crea un *fork* de su repositorio y ejecuta allí un workflow que intenta autenticarse con su proveedor de WIF y el email de su cuenta de servicio (ninguno es secreto). ¿Qué dos controles lo impiden y por qué? (Pista: la condición de atributo del proveedor y el subject de las vinculaciones `roles/iam.workloadIdentityUser`.) Además, explique por qué la cuenta de servicio tiene `roles/storage.admin` solo en los proyectos de dev y prod, y `roles/storage.objectAdmin` solo sobre el bucket del estado, en vez de `Owner` o `Editor` sobre todo.

### Parte 2. Configurar GitHub

1. Abra el repositorio `gitops-lab`. Esta es la estructura:
   ```
   gitops-lab/
   ├── .github/workflows/   terraform-plan.yml  terraform-apply.yml  drift.yml  destroy.yml
   ├── bootstrap/           bootstrap.sh
   ├── envs/dev/            main.tf  backend.tf
   ├── envs/prod/           main.tf  backend.tf
   ├── modules/static_site/ main.tf  variables.tf  outputs.tf
   ├── site/                index.html
   ├── .checkov.yaml
   └── .gitignore
   ```
2. Cree las **variables** del repositorio: *Settings → Secrets and variables → Actions → pestaña Variables → New repository variable*. Son seis:

| Variable | Valor |
|---|---|
| `GCP_WIF_PROVIDER` | `projects/<NÚMERO>/locations/global/workloadIdentityPools/github/providers/github-actions` |
| `GCP_SERVICE_ACCOUNT` | `sa-gitops-github@gitops-state-<ID>.iam.gserviceaccount.com` |
| `GCP_PROJECT_DEV` | `gitops-dev-<ID>` |
| `GCP_PROJECT_PROD` | `gitops-prod-<ID>` |
| `GCP_LOCATION` | `us-central1` |
| `TFSTATE_BUCKET` | `gitops-state-<ID>-tfstate` |

> **Variables, no secretos.** Ninguno de estos valores sirve sin un token OIDC de *su* repositorio. Por eso van en *Variables* y no en *Secrets*: que el laboratorio no necesite ningún secreto de GitHub es precisamente el punto de OIDC.

3. Cree los dos **entornos**: *Settings → Environments → New environment*, con nombres exactamente `dev` y `prod`.
   - `dev`: sin reglas de protección.
   - `prod`: active **Required reviewers** y agréguese a sí mismo. En *Deployment branches and tags* elija *Selected branches and tags* y agregue `main`.

### Parte 3. Leer el código antes de ejecutarlo

**El módulo `static_site`.** Crea el bucket, lo hace legible por cualquiera y sube `index.html`:

```hcl
locals {
  bucket_name = "${var.prefix}-${var.environment}-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "google_storage_bucket" "site" {
  name                        = local.bucket_name
  project                     = var.project_id
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels
}

resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "index" {
  name          = "index.html"
  bucket        = google_storage_bucket.site.name
  source        = var.index_file
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache, max-age=0"
}
```

- `random_string` agrega un sufijo porque el nombre de un bucket debe ser **único en todo GCP**.
- `uniform_bucket_level_access = true` desactiva las ACL por objeto: los permisos se controlan solo con IAM, en un único lugar.
- `allUsers` con `roles/storage.objectViewer` es lo que hace público el sitio: solo lectura de objetos; nadie anónimo puede listar ni escribir.
- El proveedor compara el MD5 de `site/index.html` con el del objeto en GCP (atributo `detect_md5hash`): si el archivo cambia, el objeto se **reemplaza**.
- `cache_control = "no-cache"` evita que Google sirva una copia en caché de hasta una hora; así verá la *Versión 2* apenas termine el apply.
- La URL del sitio es `https://storage.googleapis.com/<bucket>/index.html`. (A diferencia de Azure, la configuración `website` de un bucket solo aplica con dominio propio y balanceador; aquí no hace falta.)

**Las validaciones.** Las etiquetas `owner`, `environment` y `course` son obligatorias, y además deben cumplir el formato de GCP (minúsculas, dígitos, `-` y `_`). Por eso `envs/*/main.tf` usa `owner = lower(var.owner)`: un usuario de GitHub con mayúsculas rompería el `apply`, y la validación lo detecta en el `plan`, antes de tocar GCP.

```hcl
variable "labels" {
  type = map(string)

  validation {
    condition = alltrue([
      for k in ["owner", "environment", "course"] : can(var.labels[k])
    ])
    error_message = "Etiquetas obligatorias: owner, environment y course."
  }
}
```

**El backend.** El estado se guarda en Cloud Storage. El nombre del bucket no está escrito: el workflow lo entrega con `-backend-config`:

```hcl
terraform {
  backend "gcs" {
    prefix = "dev"
    # bucket se entrega con -backend-config desde el workflow
  }
}
```

**El workflow `terraform-apply.yml`.** Léalo completo en el repositorio. Las diferencias con Azure:

```yaml
    env:
      TF_VAR_project_id: ${{ matrix.env == 'prod' && vars.GCP_PROJECT_PROD || vars.GCP_PROJECT_DEV }}
    steps:
      - uses: actions/checkout@v5
      - name: Autenticarse en GCP (OIDC + Workload Identity Federation)
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}
```

- `permissions: id-token: write` autoriza al job a pedir el token OIDC. Sin esa línea no hay autenticación.
- El paso `auth` cambia el token de GitHub por credenciales de la cuenta de servicio y deja un archivo de configuración *sin secretos* (tipo `external_account`) que Terraform usa automáticamente. Ese archivo solo describe *cómo* pedir un token; no contiene ninguno.
- `matrix` con `max-parallel: 1` ejecuta primero `dev` y después `prod`; si `dev` falla, `prod` no arranca.
- `environment: ${{ matrix.env }}` vincula cada job a un entorno de GitHub: para `prod` activa la aprobación y determina el subject OIDC.
- `concurrency` garantiza que nunca haya dos despliegues a la vez.

**El workflow `terraform-plan.yml`.** El job `validate` no necesita credenciales (formato, sintaxis y Checkov). El job `plan` se autentica igual que el apply, inicializa el backend y comenta el plan en el PR.

> **Pregunta 2.** En `terraform-apply.yml`, ¿qué línea hace que `prod` espere una aprobación y qué pasaría con `prod` si el job de `dev` fallara? ¿Por qué el job necesita `permissions: id-token: write` si ya tiene las variables `GCP_*`?

### Parte 4. Primer despliegue

1. *Actions → terraform-apply → Run workflow → rama `main` → Run workflow*.
2. Abra el job `apply (dev)`. En *Init* debe aparecer `Successfully configured the backend "gcs"!`. En *Apply* busque `Plan: 4 to add, 0 to change, 0 to destroy.` y `Apply complete! Resources: 4 added`.
3. El job `apply (prod)` quedará en **Waiting**: pulse **Review deployments**, marque `prod` y **Approve and deploy**.
4. Abra el **Summary** de la ejecución: allí están las dos URLs. Ambas muestran «Versión 1».
5. Compruebe desde Cloud Shell:
   ```bash
   gcloud storage buckets list --project=gitops-dev-<ID>  --format="table(name,location,labels)"
   gcloud storage buckets list --project=gitops-prod-<ID> --format="table(name,location,labels)"
   gcloud storage ls gs://gitops-state-<ID>-tfstate/**
   ```

> **Si el primer job falla.** Al crear el repositorio desde la plantilla, GitHub pudo disparar una ejecución antes de que existieran las variables. Ignórela y use la que lanzó a mano.

> **Pregunta 3.** Copie la línea `Plan: … to add` del job de `dev` y explique cada uno de los cuatro recursos. ¿Para qué existe el `random_string`? ¿Dónde quedó guardado el estado de Terraform (muestre la salida de `gcloud storage ls`) y por qué no está en el repositorio?

### Parte 5. Proteger la rama `main`

Igual que en la guía original:

1. *Settings → Rules → Rulesets → New ruleset → New branch ruleset*.
2. Nombre: `proteger-main`. *Enforcement status*: **Active**. *Target branches → Add target → Include default branch*.
3. Active **Restrict deletions**, **Require a pull request before merging** (0 aprobaciones) y **Block force pushes**. Guarde.

Todavía no active *Require status checks to pass*: lo hará en la Parte 8.

### Parte 6. Un cambio de extremo a extremo

1. Abra `site/index.html` y pulse el lápiz. Busque el comentario «CAMBIE SOLO EL TEXTO DE LA SIGUIENTE LÍNEA» y cambie «Versión 1: desplegado desde Git con Terraform.» por «Versión 2» seguido de su nombre.
2. Al confirmar, elija **Create a new branch for this commit and start a pull request**. Rama: `cambio-pagina`. Cree el PR.
3. Espere los tres checks: `validate`, `plan (dev)` y `plan (prod)`.
4. Abra el comentario del plan: debe indicar que `module.sitio.google_storage_bucket_object.index` **must be replaced** (`detect_md5hash` *forces replacement*) y que nada más cambia.
5. Observe `validate`: formato y sintaxis pasan, pero **Checkov falla**. Es lo esperado.

> **Pregunta 4.** Explique cómo leer el plan comentado: qué significan `+`, `-`, `~` y `-/+`, y qué quiere decir «forces replacement». ¿Por qué leer el plan en el PR es la verdadera revisión de un cambio de infraestructura, más que leer el diff del código?

### Parte 7. Seguridad del código: leer, corregir y justificar

Abra el paso *Escaneo de seguridad (Checkov)* del job `validate`. Con Checkov 3.x encontrará **cuatro** reglas fallidas para GCP (el número exacto puede variar):

| Regla | Qué verifica |
|---|---|
| `CKV_GCP_78` | El bucket tiene versionado de objetos activado |
| `CKV_GCP_62` | El bucket registra los accesos (*access logs*) en otro bucket |
| `CKV_GCP_114` | La prevención de acceso público está *enforced* en el bucket |
| `CKV_GCP_28` | El bucket no es accesible de forma anónima o pública |

Cada hallazgo se **corrige o se justifica por escrito**. En este laboratorio, **corrija `CKV_GCP_78`** (y endurezca de paso la recuperación ante borrados) y **justifique las otras tres**.

1. En la rama `cambio-pagina`, edite `modules/static_site/main.tf`. Al final del recurso `google_storage_bucket`, después de `labels`, agregue:
   ```hcl
     versioning {
       enabled = true
     }

     soft_delete_policy {
       retention_duration_seconds = 604800
     }

     lifecycle_rule {
       condition {
         num_newer_versions = 3
         with_state         = "ARCHIVED"
       }
       action {
         type = "Delete"
       }
     }
   ```
   El versionado conserva las versiones anteriores de cada objeto; la eliminación temporal (*soft delete*, 7 días) permite recuperar objetos borrados; la regla de ciclo de vida evita que las versiones viejas acumulen costo. Conserve la alineación de los `=`: el check de formato la verifica.

2. Edite `.checkov.yaml`. **Escriba su propia justificación técnica en cada línea**; un comentario vacío o genérico no la sustituye:
   ```yaml
   framework:
     - terraform
   compact: true
   quiet: true
   skip-check:
     - CKV_GCP_28    # su justificación
     - CKV_GCP_114   # su justificación (vea la Pregunta 5)
     - CKV_GCP_62    # su justificación
   ```
3. Confirme los cambios en la misma rama. Los tres checks deben ponerse en verde. El plan ahora muestra, además del reemplazo del objeto, un cambio *in-place* (`~`) en el bucket.

> **Pregunta 5.** Para la regla que corrigió, explique qué riesgo mitigan el versionado y la eliminación temporal (piense en un `index.html` sobrescrito por error o en un borrado malicioso). Para `CKV_GCP_114` y `CKV_GCP_28`, explique por qué no se corrigieron aquí (pista: ¿qué le pasaría a la vinculación `allUsers` si la prevención de acceso público estuviera *enforced*?), qué arquitectura permitiría servir el sitio con el bucket privado (por ejemplo, un balanceador HTTPS con Cloud CDN delante del bucket) y qué permisos adicionales exigiría eso a la cuenta de servicio.

### Parte 8. Exigir los checks y fusionar

1. *Settings → Rules → Rulesets → `proteger-main`* → active **Require status checks to pass** y agregue `validate`, `plan (dev)` y `plan (prod)`. Guarde.
2. Vuelva al PR: el *merge* exige los tres checks en verde. Pulse **Merge pull request**.
3. En *Actions*, el merge disparó `terraform-apply`. `dev` se despliega solo y `prod` espera su aprobación.
4. Abra las dos URLs: deben mostrar «Versión 2» con su nombre.

### Parte 9. Deriva: el experimento

Ahora se rompe a propósito la coincidencia entre Git y la nube, como lo haría alguien con prisa y acceso a la consola: **desactivará el versionado** que acaba de declarar en Git.

1. En la consola: *Cloud Storage → Buckets* (seleccione el proyecto `gitops-dev-<ID>`) → abra el bucket `pemu-dev-…` → pestaña **Protección** → *Control de versiones de objetos* → **Desactivar** → confirme.
   Equivalente desde Cloud Shell (el nombre del bucket está en la URL del sitio):
   ```bash
   gcloud storage buckets update gs://pemu-dev-XXXXXX --no-versioning
   ```
2. *Actions → drift → Run workflow*. El paso *Plan (detecta deriva)* termina con código de salida 2: «hay diferencias».
3. En **Issues** aparece «Deriva detectada en dev». El plan muestra `~ versioning { ~ enabled = false -> true }`: Terraform volvería a activarlo.
4. Reconcilie a favor de Git: ejecute **terraform-apply** a mano (y apruebe `prod`). Después ejecute **drift** otra vez: no debe crear ningún issue nuevo. Cierre el issue.

| Camino | Qué se hace | Cuándo es razonable |
|---|---|---|
| **Git gana** | Se ejecuta `apply` y se deshace el cambio manual | El cambio manual fue un error o una emergencia ya resuelta |
| **La realidad gana** | Se actualiza el código y se abre un PR | El cambio manual era legítimo y debió hacerse por Git |
| **Se ignora ese atributo** | `lifecycle { ignore_changes = [...] }` | Otro sistema administra ese atributo a propósito |

> **Nota sobre etiquetas en GCP.** En la guía de Azure la deriva era una etiqueta agregada en el portal. En el proveedor `google` (versión 5 en adelante) el campo `labels` **no es autoritativo**: Terraform solo vigila las claves que declara, así que una etiqueta *nueva* agregada en la consola no aparece como deriva (sí aparecería si cambia el *valor* de `owner`, `environment` o `course`). Por eso aquí se usa el versionado. Si quiere, compruébelo: agregue una etiqueta en la consola, corra `drift` y observe que no abre issue.

> **Pregunta 6.** Adjunte la captura del issue. Explique: (a) por qué el plan muestra que Terraform *reactivaría* el versionado en lugar de aceptar el cambio; (b) qué camino de la tabla eligió y por qué; (c) qué riesgo tendría que el propio workflow `drift` aplicara la corrección automáticamente, sin revisión.

### Parte 10 (opcional). Revertir con Git

1. Abra el PR fusionado en la Parte 8 y pulse **Revert**.
2. Deje pasar los checks, fusione y apruebe `prod`.
3. Las URLs vuelven a mostrar «Versión 1». Observe quién revirtió, cuándo y por qué en el historial de commits.

---

## Preguntas finales

> **Pregunta 7.** Compare el modelo **push** de este laboratorio con el modelo **pull** de Flux o Argo CD. Indique en cada uno dónde viven las credenciales de despliegue, qué ocurre cuando alguien cambia el destino a mano y cuál escogería para administrar cincuenta clústeres de Kubernetes (por ejemplo, GKE), justificando la respuesta.

> **Pregunta 8.** Nombre tres cambios para endurecer este montaje para producción y el riesgo concreto que mitiga cada uno. Considere, por ejemplo: aplicar exactamente el plan revisado (`terraform plan -out` como artefacto) en lugar de volver a planificar; separar quien propone de quien aprueba; usar **dos cuentas de servicio**, una de solo lectura para `plan` (vinculada al subject `pull_request`) y otra para `apply` (vinculada solo a `environment:prod`); o la política de organización `iam.disableServiceAccountKeyCreation`.

## Entregables

1. Documento PDF con las respuestas a las ocho preguntas, cada una con su evidencia (captura o salida de consola).
2. URL de su repositorio público de GitHub.
3. Captura del PR de la Parte 7 con los tres checks en verde y los comentarios del plan.
4. Captura de la aprobación de `prod` (*Review deployments*) y de las dos URLs mostrando «Versión 2» con su nombre.
5. Captura del issue de deriva de la Parte 9 y del workflow `drift` sin deriva tras la corrección.
6. Evidencia de la limpieza de recursos.

> **Nada de secretos en el informe ni en el repositorio.** El proveedor de WIF, el email de la cuenta de servicio y los ID de proyecto no son secretos. Una clave JSON de cuenta de servicio, un token de acceso (`ya29.…`) o una contraseña visibles en una captura o en un archivo invalidan el criterio de autenticación sin secretos.

## Limpieza de recursos

El orden importa: primero se destruye lo que Terraform administra, mientras el estado todavía existe; después se elimina lo que creó el bootstrap.

1. *Actions → destroy → Run workflow* → escriba `destruir`. Apruebe los dos entornos.
2. Cuando termine, elimine los tres proyectos desde Cloud Shell. Esto borra también el estado, la cuenta de servicio y Workload Identity Federation:
   ```bash
   gcloud projects delete gitops-dev-<ID>   --quiet
   gcloud projects delete gitops-prod-<ID>  --quiet
   gcloud projects delete gitops-state-<ID> --quiet

   # Verifique: deben aparecer como DELETE_REQUESTED (o no aparecer)
   gcloud projects list --filter="projectId:gitops-*" \
     --format="table(projectId,lifecycleState)"
   ```
3. Capture esa salida como evidencia. GCP conserva los proyectos 30 días en estado `DELETE_REQUESTED` (sin cobrar) antes de borrarlos definitivamente; durante ese tiempo sus ID no se pueden reutilizar.

**Si usó un proyecto existente** (no creado por el bootstrap), no lo borre: elimine solo lo del laboratorio.
```bash
P=<su-proyecto>
SA=sa-gitops-github@$P.iam.gserviceaccount.com
gcloud projects remove-iam-policy-binding $P --member="serviceAccount:$SA" \
  --role=roles/storage.admin --condition=None
gcloud iam workload-identity-pools delete github --project=$P --location=global --quiet
gcloud iam service-accounts delete $SA --project=$P --quiet
gcloud storage rm -r gs://$P-tfstate
```

> **No elimine el proyecto del estado antes de ejecutar `destroy`.** Terraform perdería la memoria de lo que creó, `destroy` fallaría y tendría que borrar los buckets a mano.

## Solución de problemas

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `unauthorized_client: The given credential is rejected by the attribute condition` | El token no viene del repositorio esperado (ID de repo u owner distinto: por ejemplo, un fork o un repositorio recreado) | Vuelva a correr el bootstrap con `GH_USER` y `GH_REPO` correctos; revise la condición con `gcloud iam workload-identity-pools providers describe` |
| `Permission 'iam.serviceAccounts.getAccessToken' denied on resource` | El subject del token no tiene `roles/iam.workloadIdentityUser`: mayúsculas, nombre del repo o del entorno; o la vinculación aún se propaga | Compare con `gcloud iam service-accounts get-iam-policy`. Revise que los entornos se llamen `dev` y `prod`. Espere 5 minutos y reintente |
| `Unable to get the ACTIONS_ID_TOKEN_REQUEST_URL` o el paso `auth` falla pidiendo el token | Falta `permissions: id-token: write` | Restaure el bloque `permissions` del archivo original |
| `403 ... storage.objects.list` en *Init* | La cuenta de servicio aún no tiene `storage.objectAdmin` sobre el bucket del estado, o se propaga | Espere unos minutos; verifique con `gcloud storage buckets get-iam-policy` |
| `403 ... storage.buckets.create` en *Apply* | `GCP_PROJECT_DEV`/`PROD` mal escrita, o falta `roles/storage.admin` en ese proyecto | Revise las variables y los permisos del proyecto |
| `One or more users named in the policy do not belong to a permitted customer` | Su cuenta es institucional y la organización restringe los miembros (`iam.allowedPolicyMemberDomains`): bloquea `allUsers` | Use una cuenta personal de GCP, o pida una excepción al administrador |
| `Public access prevention is enforced` / `412 ... public access prevention` | La política de organización `storage.publicAccessPrevention` está activa | Igual que el anterior |
| `BILLING_DISABLED` o `billing account ... not found` | El proyecto no está vinculado a la facturación | `gcloud billing projects link <proyecto> --billing-account=<ID>` |
| El bootstrap falla al crear proyectos (cuota) | La cuenta tiene un límite de proyectos con facturación | Use un proyecto existente en `PROJECT_STATE/DEV/PROD` (Parte 1) |
| `apply (prod)` en *Waiting* indefinidamente | Nadie aprobó, o `prod` no tiene revisores | Pulse *Review deployments*; revise *Required reviewers* |
| Los checks `plan (dev)` no aparecen en el Ruleset | Aún no han corrido en ningún PR | Abra primero el PR, espere y vuelva al Ruleset |
| Falla el check de formato | Un `.tf` editado en la web quedó sin formato canónico | En Cloud Shell, `terraform fmt -recursive`, o corrija la alineación de los `=` |
| `Error acquiring the state lock` | Otra ejecución en curso, o una cancelada dejó el `.tflock` | Espere. Si persiste, `terraform force-unlock <ID>` con el ID del error |
| Las etiquetas fallan con `invalid label` | Mayúsculas u otros caracteres en un valor | Use `lower()`; solo minúsculas, dígitos, `-` y `_` |
| La URL devuelve `AccessDenied` | Falta la vinculación `allUsers` o el apply no terminó | Revise el apply y `gcloud storage buckets get-iam-policy gs://<bucket>` |
| La URL sigue mostrando la versión anterior | Caché del navegador | Recargue sin caché (Ctrl+Shift+R); el objeto ya tiene `no-cache` |
| `drift` no crea el issue | Issues desactivados, o no hubo deriva | Active *Issues* en *Settings → General → Features*; confirme que cambió el bucket de **dev** |
