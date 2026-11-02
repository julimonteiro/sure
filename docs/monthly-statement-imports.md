# Importação mensal local

Objetivo: importar extratos e faturas Santander/Mercado Pago e extratos Nomad pelo formulário PDF, sem provedor de IA. As contas existentes e suas moedas continuam sendo usadas.

Implementação:

1. Ler qualquer mês/ano e todas as páginas de movimentações. Guardar período, saldos e referências estáveis; conferir os totais antes da revisão.
2. Oferecer uma entrada explícita de PDF local. Documento incompatível ou divergente deve falhar com mensagem clara, sem chamar IA.
3. Publicar de forma idempotente, inclusive transações iguais no mesmo dia, e usar posições e valor de fechamento da Nomad como fotografia mensal.
4. Classificar créditos e pagamentos, criar contrapartidas das reservas e vincular pagamentos de cartão quando houver uma única fatura correspondente. Ambiguidades ficam para revisão.
5. Configurar câmbio USD/BRL do Banco Central sem chave. Preservar USD na Nomad e BRL no consolidado.
6. Testar meses distintos, virada de ano, múltiplas páginas, duplicação, reversão e divergência de valores. Validar os documentos já armazenados sem publicar novamente.

Não inferir saldo histórico de reserva nem transformar crédito desconhecido em salário. Não inserir documentos, dados pessoais ou credenciais no Git. Documentos devem permanecer no armazenamento local do app.

## Uso mensal

Em **Importações → Nova importação → Extratos e faturas mensais · sem IA**, envie um PDF original por vez. Escolha a conta existente, confira o período e o saldo apresentado, revise os lançamentos e publique. Os arquivos podem ser enviados aos poucos e em qualquer ordem entre as contas. Não crie saldos iniciais novamente.

Use o período de compras para escolher a fatura: uma fatura com vencimento em novembro pode conter as compras de outubro. Parcelas de compras antigas são lançadas no fechamento do período atual; a data original fica nas observações. Pagamentos de cartão são vinculados aos lançamentos da conta quando as duas evidências estão disponíveis, inclusive pagamentos divididos em mais de um débito.

As reservas geram transferências internas. Quando o extrato não informa o saldo histórico da reserva, o app só conhece os movimentos importados. Créditos de origem desconhecida continuam identificados para conferência. A folha de pagamento é opcional e não deve duplicar os depósitos de salário.

Na Nomad, cada documento atualiza a fotografia de caixa, posições e valor total em USD. O consolidado em BRL usa o provedor **Banco Central do Brasil · PTAX USD/BRL**, disponível nas configurações de provedores sem chave. A consulta de câmbio precisa de internet e não transmite o PDF nem os lançamentos pessoais.

O extrato simples XP informa apenas o caixa: o saldo disponível do cabeçalho pode ser da consulta atual e não do período selecionado. O importador usa os saldos dos lançamentos do período e verifica sua sequência. Para registrar o patrimônio investido na XP é necessário um documento de posição de carteira; quantidades mencionadas em rendimentos não permitem inferir seu valor.

Se o formato não for reconhecido, uma linha estiver ilegível ou os totais não fecharem, o app interrompe a importação com uma mensagem. O modo mensal não recorre a IA. PDFs digitalizados como imagens precisam de um extrato original com texto.

## Verificação local segura

`bin/test-local` usa uma imagem de testes (`Dockerfile.test-local`), o banco `sure_test`, Redis 15 e armazenamento de testes separado dos documentos do app. Construa a imagem com `docker build -f Dockerfile.test-local -t sure-local-test .`.

O ambiente de teste usa `POSTGRES_TEST_DB` e ignora `POSTGRES_DB` da instância. O helper recusa carregar fixtures fora de um banco com sufixo `_test`. Não execute testes no banco de produção. Para uma segunda execução independente, use outro `POSTGRES_TEST_DB` com esse sufixo e prepare seu schema antes.
