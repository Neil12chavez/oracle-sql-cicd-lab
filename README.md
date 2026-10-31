## En la carpeta db : 01_schema.sql
porque pesa mucho
diseña como sera el pipeline  que llevara y todo eso - github beaches - cicd powerautomation 


## EL PESO DE ORACLE - PORQUE PESA MUCHO

suele ser por el tag de faststart, lo que hay que entender es que:
- no guarda 6gb de las tablas que tenemos
- "pesa por la imagen de oracle ya que ya trae todo preparado sus archivos" -> **faststart** = nos ofrece un arranque mas rapido pero el peso de disco es mucho mayor 

### solucion: gvenzl/oracle-free:23.26.3-slim
CONTRAPARTE: 
- El primer arranque es mas lento. (crea la BD y ya no )


## diseño del pipeline

Una línea por etapa (para explicar)
1. **valida** que se pueda correr: repo limpio, docker compose válido, secretos fuera del código e imágenes pineadas.
2. **provisionamiento** levanta una BD limpia y espera a que esté healthy.
3. **Bootstrap** — inicializa el proyecto de SQLcl Projects (solo si no existe).
4. **Build** — genera los cambios y el artefacto .zip versionado 
5. **Deploy** — aplica ese artefacto a la BD 
6. **Verify** — comprueba que el esquema y los datos quedaron bien.
7. **Rollback** (si verify falla) 
8. Report — guarda logs, versión.