## PostHog is installed

**Create the owner account.** Open the app and sign up. The first account becomes the instance
owner; self-hosted PostHog cannot create a second organisation, so keep this one.

Cloudron sign-in is not wired up: PostHog's OIDC/SAML support is an enterprise feature. Use the
email and password you set here, and keep it somewhere safe — there is no password reset by email
unless the mail addon is configured.

### Sending events

1. In **Project settings → Web snippet**, copy the project API key.
2. Point your site at this app:

   ```js
   posthog.init('<project-api-key>', {
     api_host: 'https://<this-app>',
     ui_host: 'https://<this-app>',
     person_profiles: 'identified_only'
   })
   ```

3. Events appear under **Activity → Live events** within a few seconds.

### First things to know

- **Analytics data lives in ClickHouse**, outside the ordinary `/app/data` backup folder, so its
  background merges cannot abort your whole server's backup run (a known Cloudron issue for any
  ClickHouse app). A dump of it is written into the backup at backup time; see the project README.
- **The first boot takes a while.** Migrations run before the services start; the app answers its
  health check immediately, so Cloudron will not time out. Expect tens of minutes on a fresh
  install, and check the app log for `[init] ready: services may start`.
- **Feature flags and session replay** work out of the box. **Data warehouse syncs, batch exports
  and CDP destination delivery are not included** in this version.
