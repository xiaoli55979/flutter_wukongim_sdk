# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.4] - 2025-12-24
### Fixed
- Fixed asset loading issue for sql.txt file in package configuration
- Improved asset path resolution for Flutter packages
- Enhanced database initialization reliability

## [0.0.3] - 2025-12-24
### Fixed
- Code formatting and analysis issues
- Example project compilation errors
- Asset configuration and database initialization


## [0.0.2] - 2025-12-23

### Changed
- Updated project structure and code organization
- Improved example applications with better error handling
- Enhanced debugging tools and connection diagnostics
- Refined documentation and setup instructions

### Fixed
- Code formatting and analysis issues
- Example project compilation errors
- Asset configuration and database initialization

### Added
- Debug example with detailed connection analysis
- Connection troubleshooting guide
- Improved error messages and logging

## [0.0.1] - 2025-12-23

### Added
- Initial release of Flutter WuKongIM SDK
- Real-time messaging functionality with WebSocket support
- End-to-end encryption using x25519 key exchange
- Channel management (create, join, leave channels)
- Message types support: text, image, voice, video, card
- Conversation management with unread message counting
- Local SQLite database for message persistence
- Automatic reconnection with exponential backoff
- Message resend mechanism for failed messages
- Multi-environment support (development, testing, staging, production)
- Connection status monitoring and error handling
- Comprehensive example application with debugging tools

### Features
- **Core Messaging**: Send and receive various message types
- **Channel Management**: Group and personal chat support
- **Offline Support**: Local message storage and sync
- **Security**: End-to-end encryption with x25519
- **Reliability**: Auto-reconnect and message resend
- **Cross-platform**: iOS and Android support
- **Developer Tools**: Debug example with detailed logging

### Dependencies
- Flutter SDK >=3.3.0
- Dart SDK ^3.10.1
- Key packages: encrypt, sqflite, web_socket_channel, connectivity_plus

### Documentation
- Comprehensive README with setup instructions
- API documentation with code examples
- Connection troubleshooting guide
- Example applications for different use cases