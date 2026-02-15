# Homelab GitOps

## Visão Geral
Este repositório gerencia a infraestrutura e as aplicações para um cluster Kubernetes de homelab usando princípios de GitOps. Ele utiliza ArgoCD para implantação contínua, Kustomize para personalização de manifestos Kubernetes e External Secrets Operator com Infisical para gerenciamento seguro de segredos.

## Tecnologias Utilizadas
-   **Kubernetes:** Plataforma de orquestração de containers.
-   **ArgoCD:** Entrega contínua declarativa de GitOps para Kubernetes.
-   **Kustomize:** Personalização de configurações Kubernetes.
-   **External Secrets Operator + Infisical:** Sincroniza segredos armazenados no Infisical diretamente para o cluster Kubernetes.
-   **Pilha de Monitoramento:**
    -   **Compatível com Prometheus:** Para monitoramento de séries temporais.
    -   **Grafana:** Para visualização de dados e dashboards.
    -   **Alertmanager:** Para gerenciamento e roteamento de alertas.
    -   **VictoriaMetrics:** Uma solução de monitoramento de alto desempenho, escalável e econômica (alternativa/melhoria ao Prometheus).
-   **Cloudflare Tunnel:** Expõe serviços com segurança à internet sem a necessidade de abrir portas de entrada em seu firewall.
-   **n8n:** Uma poderosa ferramenta de automação de fluxo de trabalho.
-   **Exporters:** Vários exporters Prometheus para coletar métricas de diferentes serviços:
    -   **Node Exporter:** Coleta métricas de nível de host de nós Kubernetes.
    -   **PiHole Exporter:** Exporta métricas de instâncias Pi-Hole.
    -   **PVE Exporter:** Exporta métricas de hosts do Proxmox Virtual Environment.
    -   **Speedtest Exporter:** Executa periodicamente testes de velocidade da internet e expõe os resultados como métricas.

## Estrutura do Repositório

-   `argocd/`: Contém as definições de Aplicação do ArgoCD.
    -   `root-app.yaml`: A Aplicação ArgoCD primária que orquestra a implantação de todas as outras aplicações definidas neste repositório.
    -   `infra/`: Definições individuais de Aplicações ArgoCD para vários componentes de infraestrutura, referenciando bases Kustomize no diretório `infra/`.

-   `infra/`: Armazena os manifestos base do Kubernetes, organizados por aplicação, principalmente usando Kustomize.
    -   Cada subdiretório (por exemplo, `cloudflare-tunnel`, `exporters`, `monitoring`, `n8n`) representa uma aplicação ou pilha distinta, contendo suas definições Kustomize `base/`.
    -   `exporters/`: Contém as bases Kustomize para todos os exporters Prometheus configurados.
    -   `monitoring/`: Contém as bases Kustomize para os componentes da pilha de monitoramento principal (VictoriaMetrics, Grafana, Alertmanager, etc.).
    -   `external-secrets/`: Contém o ClusterSecretStore do Infisical e recursos relacionados.

-   `docs/`: Contém documentação suplementar, planos arquitetônicos e outras informações relevantes.

## Primeiros Passos (Visão Geral Conceitual)

Para que esta infraestrutura de homelab seja implantada, você geralmente seguiria estes passos conceituais:

1.  **Pré-requisitos:**
    *   Um cluster Kubernetes funcional.
    *   ArgoCD instalado e configurado em seu cluster.
    *   External Secrets Operator instalado no cluster (gerido via ArgoCD).
    *   Conta no Infisical com os segredos configurados.

2.  **Configuração Inicial do ArgoCD:**
    *   Aplique o manifesto `argocd/root-app.yaml` à sua instância ArgoCD. Esta aplicação atua como a "raiz de confiança" e descobrirá e sincronizará automaticamente todas as aplicações filhas definidas em `argocd/infra/`.

3.  **Gerenciamento de Segredos:**
    *   Os segredos são geridos no Infisical e sincronizados para o cluster via External Secrets Operator. Cada aplicação tem um `ExternalSecret` que referencia as chaves no Infisical através do `ClusterSecretStore`.

4.  **Personalização:**
    *   Modifique os diretórios Kustomize `base/` dentro de `infra/` para ajustar configurações, limites de recursos e outras definições para corresponder ao seu ambiente de homelab específico e preferências.

## Aplicações e Serviços Implantados

Este repositório gerencia uma variedade de serviços essenciais de homelab:

-   **Pilha de Monitoramento:** Uma solução de monitoramento abrangente que fornece coleta de métricas, visualização e alertas para seu cluster Kubernetes e serviços integrados.
-   **Cloudflare Tunnel:** Estabelece conexões seguras e somente de saída para a borda da Cloudflare, permitindo que você exponha serviços internos publicamente sem abrir portas em sua rede doméstica.
-   **n8n:** Fornece uma plataforma de automação de fluxo de trabalho auto-hospedada, poderosa e extensível para conectar vários serviços e automatizar tarefas.
-   **Prometheus Exporters:** Coletam e expõem continuamente métricas de diferentes componentes do seu homelab para consumo pela pilha de monitoramento.

## Gerenciamento de Segredos com External Secrets

O External Secrets Operator sincroniza segredos do Infisical para o cluster Kubernetes.
-   Cada aplicação que necessita de segredos tem um ficheiro `*-externalsecret.yaml` no seu diretório `base/`.
-   Os segredos são organizados por pasta no Infisical (ex: `/cloudflare/`, `/n8n/`, `/pve-exporter/`, `/pihole-exporter/`).
-   O `ClusterSecretStore` está definido em `infra/external-secrets/base/` e aponta para o projeto Infisical.
