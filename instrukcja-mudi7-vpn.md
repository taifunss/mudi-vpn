# Instrukcja instalacji VPN – GL.iNet Mudi 7

---

## Co potrzebujesz
- Router GL.iNet Mudi 7
- Kartę SIM
- Telefon z Androidem
- Login i hasło VPN (dostaniesz ode mnie)
- Dostęp do sieci Wi-Fi z internetem (np. domowe Wi-Fi)

---

## Krok 1 – Pierwsze uruchomienie

1. Włóż kartę SIM do Mudi 7
2. Naciśnij przycisk zasilania
3. Poczekaj ~60 sekund aż router się uruchomi
4. Na ekranie dotykowym Mudi pojawi się kreator pierwszego uruchomienia
5. Ustaw **hasło do panelu routera** – zapamiętaj je!
6. Ustaw **hasło do Wi-Fi** – zapamiętaj je!

---

## Krok 2 – Połącz telefon z Wi-Fi Mudi

1. Wejdź w ustawienia Wi-Fi na telefonie
2. Znajdź sieć **GL-E5800-XXXX**
3. Wpisz hasło które ustawiłeś w kroku 1
4. Połącz się

---

## Krok 3 – Włącz Repeater na ekranie Mudi

Potrzebujesz internetu do instalacji skryptu. Karta SIM jest pusta więc użyjesz domowego Wi-Fi przez Repeater.

1. Na ekranie dotykowym Mudi kliknij **Repeater**
2. Wybierz swoją sieć domową Wi-Fi
3. Wpisz hasło do domowego Wi-Fi
4. Poczekaj aż połączy się z internetem

---

## Krok 4 – Pobierz Termux

1. Otwórz **Google Play Store** na telefonie
2. Wyszukaj **Termux**
3. Zainstaluj i otwórz

---

## Krok 5 – Instalacja VPN

W Termux wpisz kolejno:

**Komenda 1** – usuń stary klucz SSH:
```
ssh-keygen -R 192.168.8.1
```

**Komenda 2** – połącz się z routerem:
```
ssh root@192.168.8.1
```
- Gdy pojawi się pytanie wpisz `yes` i naciśnij Enter
- Wpisz **hasło do panelu** które ustawiłeś w kroku 1

**Komenda 3** – zainstaluj VPN:
```
curl -s https://raw.githubusercontent.com/taifunss/mudi-vpn/main/install.sh -o /tmp/install.sh && sh /tmp/install.sh
```
- Gdy zapyta **"Wpisz swoj login VPN"** – wpisz login który dostałeś ode mnie
- Gdy zapyta **"Wpisz swoje haslo VPN"** – wpisz hasło które dostałeś ode mnie
- Poczekaj aż pojawi się napis **"Instalacja zakonczona"**

---

## Krok 6 – Wyłącz Repeater

Po zakończeniu instalacji wyłącz Repeater.

1. Na ekranie dotykowym Mudi kliknij **Repeater**
2. Wyłącz połączenie z domowym Wi-Fi

---

## Krok 7 – Sprawdź czy działa

1. Odłącz telefon od Wi-Fi Mudi i połącz ponownie
2. Otwórz przeglądarkę
3. Wejdź na `ifconfig.me`
4. Jeśli pokazuje inne IP niż normalnie – **VPN działa!**

---

## Od teraz codziennie

1. Podłącz telefon/laptop/TV do Wi-Fi Mudi
2. Internet przez VPN działa automatycznie

---

## Coś nie działa?

Napisz do mnie podając swój login – pomogę.
