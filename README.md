# Vehicle Log

A simple, private app for keeping track of your vehicles: fuel, mileage, servicing, MOT dates and reminders. It runs on Android and desktop (Linux now, Windows planned), keeps everything on your own devices, and can sync between them through a file share on your own network. There is no account and no cloud service.

## Features

- Several vehicles, each with registration, make, model, year, tank capacity, mileage and MOT date
- Fuel log with full-tank tracking and fuel economy worked out from full tank to full tank
- Service and maintenance history with costs and notes
- Service reminders by distance, by time, or both, plus an MOT countdown
- Android notifications for MOT and service reminders that are due soon or overdue (off by default)
- Charts: fuel economy, price per litre, and monthly spending on fuel and servicing
- Kilometres and L/100km, or miles and MPG; choose your own currency symbol
- Works offline. Data is stored on the device in a local database
- Sync between devices using a Samba (SMB) share, on app open, after changes, in the background on Android, and on demand
- CSV export and import for backups or moving data in from a spreadsheet

## Status

Personal project, in active development. It is tested on Linux (Debian) and Android. Windows should work but has not been tested yet. iOS and macOS are not supported.

## Privacy

All data stays on your devices and on the share you set up. The app has no analytics, no accounts and no servers of its own. The sync password is kept in the system's secure storage.

## Licence

GNU General Public License v3.0. See [LICENSE](LICENSE).
