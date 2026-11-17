# hermes-broker

La seule porte vers root pour l'agent Hermes. L'agent n'a aucun privilege : il
peut seulement **demander**, et le broker n'execute que ce qu'une preuve humaine
a autorise.

## Pourquoi

`nixos-rebuild` est deja en NOPASSWD scopé, mais tout le reste (redemarrer une
unite, lire un fichier root, reparer un chemin) obligeait a demander un mot de
passe dans le chat. Le broker remplace cette saisie par un choix de preuves, sans
elargir les droits de l'agent d'un pouce.

## Flux

1. L'agent (utilisateur `hermes`) ecrit `{argv, cwd, reason}` sur
   `/run/hermes-broker/broker.sock`. Le noyau attribue l'appel a son uid via
   `SO_PEERCRED`, il n'y a aucun secret a voler cote agent.
2. Le broker (root) rend un jeton a usage unique valable `BROKER_TTL` (300 s) et
   publie la commande exacte sur `https://broker.marcpartensky.com/r/<jeton>`.
3. Marc prouve son identite par le canal qu'il veut : mot de passe systeme
   (PAM) ou passkey WebAuthn (Touch ID du Mac, empreinte du telephone,
   Bitwarden, cle materielle). Tous les canaux sont armes en meme temps et la
   **premiere** preuve valide consomme la demande.
4. Le broker execute la commande en root, journalise l'appel dans
   `/var/lib/hermes-broker/audit.jsonl`, et rend stdout/stderr/rc a l'agent.

## Utilisation cote agent

```
hermes-request --reason "redemarrer nginx apres changement de vhost" -- \
  systemctl restart nginx
```

Le client affiche l'URL d'approbation sur stderr des que la demande est en
attente, puis les sorties de la commande.

## Enrolement d'une passkey

```
https://broker.marcpartensky.com/enroll
```

Le mot de passe systeme autorise l'enrolement (une fois), puis
`navigator.credentials.create()` enregistre la passkey. La verification exige le
flag `user-verification`, donc un geste biometrie ou un PIN a chaque assertion.
Plusieurs passkeys peuvent coexister (Mac, telephone, Bitwarden) ; `creds.json`
ne contient que des cles **publiques**.

## Etat

- `/var/lib/hermes-broker/creds.json` : passkeys enregistrees (cles publiques)
- `/var/lib/hermes-broker/audit.jsonl` : une ligne par approbation, refus,
  expiration et execution
- journal : `journalctl -u hermes-broker`

## Ce qui a ete abandonne

Un binaire maison utilisant une cle du Secure Enclave avec ACL
`biometryCurrentSet` aurait donne un dialogue natif Touch ID sans navigateur.
macOS refuse : il faut l'entitlement `keychain-access-groups`, qui exige une
identite Apple Developer. En signature ad-hoc l'ajout de la cle echoue en
`-34018` (missing entitlement), et poser l'entitlement sur un binaire ad-hoc fait
tuer le processus par le noyau (SIGKILL). WebAuthn dans Chrome, signe par Apple,
donne la meme cle materielle sans certificat ; le prix est que la page
d'approbation doit etre ouverte.

## Tests

`python3 test_broker.py` (hors NixOS, dans le dossier source) verifie le cycle
complet sans materiel : page, options WebAuthn, verification ES256, refus d'une
signature alteree, mauvais rpId, absence de verification utilisateur, expiration,
execution reelle et audit.
