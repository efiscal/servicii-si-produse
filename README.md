# MANUAL DE INSTALARE A SISTEMULUI ECC S/P v1.0


### VERSIUNEA v1.0 ESTE LA MOMENTUL DE FATA SPRE CERTIFICARE

| Cerințe | Descriere |
|-------------------|-----------------------|
| Sistem de Operare Linux       | RockyLinux min. 9 / RHEL min. 9 / CentOS min. 9 / Ubuntu min 22.04  sau alt tip/versiune ce suporta versiunea minimă Docker|
| Docker Engine                 | Versiunea minimă este: 27.5.1  |
| Pachete necesare              | zip, git |
| Parametrii Tehnici            | CPU (AMD64/ARM64 min 6 Core-uri / 3000 MHz) \| RAM 16 GB \| Disk Storage: min. 300 GB \| Port 8443/TCP & 8443/UDP |
| Experienta | Experienta min.: System Administrator |

#### SUMELE DE CONTROL (CHECKSUMS) SHA-256
- LINUX/AMD64 - 035c8814a58237bfb193e90f929c5a0644b1ef00f830d23829473f1a1b2c69de
- LINUX/ARM64 - fcb1de67582e40b17fb8685cdcc8b2627f50ed0c4ac263cf736f319d4ee60b7a


#### OS-ul poate fi lansat prin mai multe modalități, cum ar fi:
- Instalând sistemul operational Linux propriu-zis pe hardware.
- Rulând un WSL (Windows Subsystem for Linux) cum ar fi Ubuntu sau RockyLinux în cadrul sistemului Windows (îl puteți instala de pe Online Microsoft Store/Market).
- Virtualizând sistemul Linux în cadrul unui hypervizor.


#### Urmatii pasii de instalare si lansare a ECC-ului:
1. Instalați "Docker Engine" de pe site-ul oficial Docker urmărind link-ul de mai jos (Versiunea minimă este: 27.5.1):
    [Instalare Docker Engine](https://docs.docker.com/engine/install/)

2. După instalare, este recomandat să activați AutoStart-ul și să faceți un reboot la OS pentru a fi aplicate regulile Firewall (iptables) corect.
    - Activarea autostart-ului
        ```sh
        systemctl enable docker --now
        ```

3. După reboot, asigurați-vă că serviciul Docker funcționează corect:
    ```sh
    systemctl status docker
    ```

4. Instalați instrumentele necesare:

    RockyLinux / RHEL / AlmaLinux / CentOS / Fedora:
    ```sh
    dnf install git zip -y
    ```
    sau
    ```sh
    yum install git zip -y
    ```

    Ubuntu:
    ```sh
    apt update && apt install git zip -y
    ```


5. Clonati proiectul de pe GitHub urmând comanda de mai jos sau il puteti descarca accesind acelasi link prin Browser:
    ```sh
    git clone --depth 1 -b v1.0 https://github.com/efiscal/sp.git ecc-sp
    ```

6. Accesați folderul care a fost clonat de pe GitHub:
    ```sh
    cd ecc-sp
    ```

7. Aflându-vă în cadrul folderului clonat, puteți executa următoarele comenzi:

    - Pentru crearea și lansarea sistemului ECC în regim "background" (în cazul în care acesta a fost deja creat anterior, acesta va verifica):
      ```sh
      ./bin/start.sh
      ```

    - Pentru oprirea sistemului ECC fără eliminarea resurselor:
      ```sh
      ./bin/stop.sh
      ```

    - Pentru distrugerea completă a resurselor sistemului ECC:
      ```sh
      ./bin/destroy.sh
      ```

    - Pentru distrugerea completă sistemului ECC si a volumelor cu informatii:
      ```sh
      ./bin/destroy-data.sh
      ```

    - Pentru generarea sumei de control (Checksum) a aplicației ECC folosind algoritmul SHA-256:
      ```sh
      ./checksum.sh
      ```

    - Pentru crearea unei arhive a aplicației ECC:
      ```sh
      ./archive.sh
      ```
8. Dupa lansarea sistemului pentru prima data folosind comanda ./bin/start.sh, este nevoie de instalat licenta care v-a fost emisa de catre "Fiscal Partner", pentru aceasta este nevoie s-o aveti pe disk-ul local pentru ca mai apoi s-o incarcati prin Browser
  9.1 Pentru incarcarea licentei este nevoie sa accesati prin Browser acest link: https://localhost:8443

9. Pentru mai multe detalii, va rugam sa cititi manualul oficial de instalare care v-a transmis Fiscal Partner!