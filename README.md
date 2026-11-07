# Sistemas Digitais (EEL480) - UFRJ

![VHDL](https://img.shields.io/badge/Language-VHDL-blue.svg)
![FPGA](https://img.shields.io/badge/Hardware-Spartan--3-orange.svg)
![University](https://img.shields.io/badge/UFRJ-Sistemas%20Digitais-red.svg)

Este repositório contém os projetos práticos desenvolvidos para a disciplina de **Sistemas Digitais (EEL480)** da Universidade Federal do Rio de Janeiro (UFRJ). 

Os trabalhos abordam o projeto, a descrição em VHDL e a síntese em hardware (FPGA Xilinx Spartan-3) de sistemas digitais complexos, envolvendo máquinas de estados, caminho de dados (*datapath*), mitigação de ruído mecânico (*debounce*) e interface com periféricos.

---

## 👥 Autores

* **Matheus Nunes da Silva**
* **Marcus Vinícius Alves Leandro**
* **Luiz Henrique de Oliveira Vettorazzi**

---

## 📁 Estrutura do Repositório

O repositório está dividido em dois diretórios principais, correspondentes a cada Trabalho Prático (TP) da disciplina:

### 1. [`/Trabalho1`](./Trabalho1) - Unidade Lógica e Aritmética (ULA) de 4 Bits
Projeto de uma ULA de 4 bits com suporte a 8 operações (incluindo soma e subtração em complemento a 2). O sistema recebe operandos sequencialmente através do mesmo barramento de 4 chaves da placa, controlados por uma Máquina de Estados Finitos (FSM) e confirmados por um botão com filtro digital de *debounce*.
* **Entrada de Dados:** 4 chaves seletoras (*switches*) configuram a operação e os operandos em 3 etapas sequenciais, avançadas por um botão de confirmação.
* **Saída de Dados:** LEDs da placa exibem o resultado final (4 bits) e as 4 *flags* de estado simultaneamente (*Zero*, *Negativo*, *Carry Out* e *Overflow*).
* **Destaques do Projeto:** Tratamento e mitigação do fenômeno de *Bouncing* mecânico, multiplexação temporal de entradas físicas restritas e arquitetura RTL combinacional acoplada a um controle síncrono.

### 2. [`/Trabalho2`](./Trabalho2) - Interface com Teclado e Display
Projeto de um sistema digital interativo implementado na FPGA, com ênfase na decodificação de sinais e comunicação com periféricos externos. A funcionalidade principal do sistema foi idealizada e proposta pelo próprio grupo.
* **Entrada de Dados:** Varredura e leitura através de um teclado, garantindo a correta diferenciação das teclas pressionadas pelo usuário.
* **Saída de Dados:** Exibição dinâmica de informações através do display da placa.
* **Destaques do Projeto:** Desenvolvimento de controladores de interface customizados, decodificação matricial e controle de varredura/multiplexação para displays.