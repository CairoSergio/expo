/**
 * Copyright © 2022 650 Industries.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */
import { getConfig } from '@expo/config';
import { prependMiddleware } from '@expo/dev-server';
import * as runtimeEnv from '@expo/env';
import assert from 'assert';
import chalk from 'chalk';
import path from 'path';

import { Log } from '../../../log';
import getDevClientProperties from '../../../utils/analytics/getDevClientProperties';
import { logEventAsync } from '../../../utils/analytics/rudderstackClient';
import { env } from '../../../utils/env';
import { getFreePortAsync } from '../../../utils/port';
import { BundlerDevServer, BundlerStartOptions, DevServerInstance } from '../BundlerDevServer';
import { getStaticRenderFunctions } from '../getStaticRenderFunctions';
import { CreateFileMiddleware } from '../middleware/CreateFileMiddleware';
import { HistoryFallbackMiddleware } from '../middleware/HistoryFallbackMiddleware';
import { InterstitialPageMiddleware } from '../middleware/InterstitialPageMiddleware';
import { ReactDevToolsPageMiddleware } from '../middleware/ReactDevToolsPageMiddleware';
import {
  DeepLinkHandler,
  RuntimeRedirectMiddleware,
} from '../middleware/RuntimeRedirectMiddleware';
import { ServeStaticMiddleware } from '../middleware/ServeStaticMiddleware';
import { ServerNext, ServerRequest, ServerResponse } from '../middleware/server.types';
import { typescriptTypeGeneration } from '../type-generation';
import { instantiateMetroAsync } from './instantiateMetro';
import { metroWatchTypeScriptFiles } from './metroWatchTypeScriptFiles';
import { observeFileChanges } from './waitForMetroToObserveTypeScriptFile';
import { htmlFromSerialAssets } from '@expo/metro-config/build/serializer';
import { createBundleUrlPath, resolveMainModuleName } from '../middleware/ManifestMiddleware';
import { SerialAsset } from '@expo/metro-config/build/getCssDeps';

const debug = require('debug')('expo:start:server:metro') as typeof console.log;

/** Default port to use for apps running in Expo Go. */
const EXPO_GO_METRO_PORT = 19000;

/** Default port to use for apps that run in standard React Native projects or Expo Dev Clients. */
const DEV_CLIENT_METRO_PORT = 8081;

export class MetroBundlerDevServer extends BundlerDevServer {
  private metro: import('metro').Server | null = null;

  get name(): string {
    return 'metro';
  }

  async resolvePortAsync(options: Partial<BundlerStartOptions> = {}): Promise<number> {
    const port =
      // If the manually defined port is busy then an error should be thrown...
      options.port ??
      // Otherwise use the default port based on the runtime target.
      (options.devClient
        ? // Don't check if the port is busy if we're using the dev client since most clients are hardcoded to 8081.
          Number(process.env.RCT_METRO_PORT) || DEV_CLIENT_METRO_PORT
        : // Otherwise (running in Expo Go) use a free port that falls back on the classic 19000 port.
          await getFreePortAsync(EXPO_GO_METRO_PORT));

    return port;
  }

  /** Get routes from Expo Router. */
  async getRoutesAsync() {
    const url = this.getDevServerUrl();
    assert(url, 'Dev server must be started');
    const { getManifest } = await getStaticRenderFunctions(this.projectRoot, url, {
      // Ensure the API Routes are included
      environment: 'node',
    });
    return getManifest({ fetchData: true });
  }

  async composeResourcesWithHtml({
    mode,
    resources,
    template,
  }: {
    mode: 'development' | 'production';
    resources: SerialAsset[];
    template: string;
  }) {
    const isDev = mode === 'development';
    return htmlFromSerialAssets(resources, {
      dev: isDev,
      template,
      bundleUrl: isDev
        ? createBundleUrlPath({
            platform: 'web',
            mode,
            mainModuleName: resolveMainModuleName(
              this.projectRoot,
              getConfig(this.projectRoot),
              'web'
            ),
          })
        : undefined,
    });
  }

  async getStaticRenderFunctionAsync({
    mode,
  }: // resources,
  {
    mode: 'development' | 'production';
    // resources: SerialAsset[];
  }) {
    const url = this.getDevServerUrl()!;

    const { getStaticContent } = await getStaticRenderFunctions(this.projectRoot, url, {
      minify: mode === 'production',
      dev: mode !== 'production',
      // Ensure the API Routes are included
      environment: 'node',
    });
    return async (path: string) => {
      return getStaticContent(new URL(path, url));
    };
  }

  async getStaticPageWithResourcesAsync(
    pathname: string[],
    {
      mode,
      resources,
    }: {
      mode: 'development' | 'production';
      resources: SerialAsset[];
    }
  ) {
    const url = this.getDevServerUrl()!;
    const bundleStaticHtml = async (): Promise<string[]> => {
      const { getStaticContent } = await getStaticRenderFunctions(this.projectRoot, url, {
        minify: mode === 'production',
        dev: mode !== 'production',
        // Ensure the API Routes are included
        environment: 'node',
      });
      return Promise.all(pathname.map((pathname) => getStaticContent(new URL(pathname, url))));
    };

    return await Promise.all(
      (
        await bundleStaticHtml()
      ).map((template) =>
        this.composeResourcesWithHtml({
          mode,
          resources,
          template,
        })
      )
    );
  }

  async getStaticResourcesAsync({ mode }: { mode: string }): Promise<SerialAsset[]> {
    const isDev = mode === 'development';
    const devBundleUrlPathname = createBundleUrlPath({
      platform: 'web',
      mode,
      mainModuleName: resolveMainModuleName(this.projectRoot, getConfig(this.projectRoot), 'web'),
    });

    const bundleUrl = new URL(devBundleUrlPathname, this.getDevServerUrl()!);
    bundleUrl.searchParams.set('platform', 'web');
    bundleUrl.searchParams.set('dev', String(isDev));
    bundleUrl.searchParams.set('minify', String(!isDev));
    bundleUrl.searchParams.set('serializer.export', 'html');
    // bundleUrl.searchParams.set('resolver.environment', 'node');

    // Fetch the generated HTML from our custom Metro serializer
    const results = await fetch(bundleUrl.toString());

    const txt = await results.text();

    try {
      return JSON.parse(txt);
    } catch (error) {
      console.log('error', error);
      console.log('txt', txt);
      throw error;
    }

    //   return await results.json();
  }

  async getStaticPageAsync(
    pathname: string,
    {
      mode,
    }: {
      mode: 'development' | 'production';
    }
  ) {
    const isDev = mode === 'development';
    const devBundleUrlPathname = createBundleUrlPath({
      platform: 'web',
      mode,
      mainModuleName: resolveMainModuleName(this.projectRoot, getConfig(this.projectRoot), 'web'),
    });
    const bundleResources = async () => {
      const bundleUrl = new URL(devBundleUrlPathname, this.getDevServerUrl()!);
      bundleUrl.searchParams.set('platform', 'web');
      bundleUrl.searchParams.set('dev', String(isDev));
      bundleUrl.searchParams.set('minify', String(!isDev));
      bundleUrl.searchParams.set('serializer.export', 'html');

      // Fetch the generated HTML from our custom Metro serializer
      const results = await fetch(bundleUrl.toString());

      const txt = await results.text();

      try {
        return JSON.parse(txt);
      } catch (error) {
        console.log('error', error);
        console.log('txt', txt);
        throw error;
      }
    };

    const bundleStaticHtml = async (): Promise<string> => {
      const { getStaticContent } = await getStaticRenderFunctions(
        this.projectRoot,
        this.getDevServerUrl()!,
        {
          minify: mode === 'production',
          dev: mode !== 'production',
          // Ensure the API Routes are included
          environment: 'node',
        }
      );

      const location = new URL(pathname, this.getDevServerUrl()!);
      return await getStaticContent(location);
    };

    const [resources, staticHtml] = await Promise.all([bundleResources(), bundleStaticHtml()]);

    const content = await this.composeResourcesWithHtml({
      mode,
      resources,
      template: staticHtml,
    });

    return {
      content,
      resources,
    };
  }

  async watchEnvironmentVariables() {
    if (!this.instance) {
      throw new Error(
        'Cannot observe environment variable changes without a running Metro instance.'
      );
    }
    if (!this.metro) {
      // This can happen when the run command is used and the server is already running in another
      // process.
      debug('Skipping Environment Variable observation because Metro is not running (headless).');
      return;
    }

    const envFiles = runtimeEnv
      .getFiles(process.env.NODE_ENV)
      .map((fileName) => path.join(this.projectRoot, fileName));

    observeFileChanges(
      {
        metro: this.metro,
        server: this.instance.server,
      },
      envFiles,
      () => {
        debug('Reloading environment variables...');
        // Force reload the environment variables.
        runtimeEnv.load(this.projectRoot, { force: true });
      }
    );
  }

  protected async startImplementationAsync(
    options: BundlerStartOptions
  ): Promise<DevServerInstance> {
    options.port = await this.resolvePortAsync(options);
    this.urlCreator = this.getUrlCreator(options);

    const parsedOptions = {
      port: options.port,
      maxWorkers: options.maxWorkers,
      resetCache: options.resetDevServer,

      // Use the unversioned metro config.
      // TODO: Deprecate this property when expo-cli goes away.
      unversioned: false,
    };

    const { metro, server, middleware, messageSocket } = await instantiateMetroAsync(
      this,
      parsedOptions
    );

    const manifestMiddleware = await this.getManifestMiddlewareAsync(options);

    // We need the manifest handler to be the first middleware to run so our
    // routes take precedence over static files. For example, the manifest is
    // served from '/' and if the user has an index.html file in their project
    // then the manifest handler will never run, the static middleware will run
    // and serve index.html instead of the manifest.
    // https://github.com/expo/expo/issues/13114

    prependMiddleware(middleware, manifestMiddleware.getHandler());

    middleware.use(
      new InterstitialPageMiddleware(this.projectRoot, {
        // TODO: Prevent this from becoming stale.
        scheme: options.location.scheme ?? null,
      }).getHandler()
    );
    middleware.use(new ReactDevToolsPageMiddleware(this.projectRoot).getHandler());

    const deepLinkMiddleware = new RuntimeRedirectMiddleware(this.projectRoot, {
      onDeepLink: getDeepLinkHandler(this.projectRoot),
      getLocation: ({ runtime }) => {
        if (runtime === 'custom') {
          return this.urlCreator?.constructDevClientUrl();
        } else {
          return this.urlCreator?.constructUrl({
            scheme: 'exp',
          });
        }
      },
    });
    middleware.use(deepLinkMiddleware.getHandler());

    middleware.use(new CreateFileMiddleware(this.projectRoot).getHandler());

    // Append support for redirecting unhandled requests to the index.html page on web.
    if (this.isTargetingWeb()) {
      // This MUST be after the manifest middleware so it doesn't have a chance to serve the template `public/index.html`.
      middleware.use(new ServeStaticMiddleware(this.projectRoot).getHandler());

      if (env.EXPO_USE_STATIC) {
        middleware.use(async (req: ServerRequest, res: ServerResponse, next: ServerNext) => {
          if (!req?.url) {
            return next();
          }

          // TODO: Formal manifest for allowed paths
          if (req.url.endsWith('.ico')) {
            return next();
          }
          if (req.url.includes('serializer.export=html')) {
            return next();
          }

          try {
            const { content } = await this.getStaticPageAsync(req.url!, {
              mode: options.mode ?? 'development',
            });

            res.setHeader('Content-Type', 'text/html');
            res.end(content);
            return;
          } catch (error: any) {
            console.error(error);
            res.setHeader('Content-Type', 'text/html');
            res.end(getErrorResult(error));
          }
        });
      }

      // This MUST run last since it's the fallback.
      if (!env.EXPO_USE_STATIC) {
        middleware.use(
          new HistoryFallbackMiddleware(manifestMiddleware.getHandler().internal).getHandler()
        );
      }
    }
    // Extend the close method to ensure that we clean up the local info.
    const originalClose = server.close.bind(server);

    server.close = (callback?: (err?: Error) => void) => {
      return originalClose((err?: Error) => {
        this.instance = null;
        this.metro = null;
        callback?.(err);
      });
    };

    this.metro = metro;
    return {
      server,
      location: {
        // The port is the main thing we want to send back.
        port: options.port,
        // localhost isn't always correct.
        host: 'localhost',
        // http is the only supported protocol on native.
        url: `http://localhost:${options.port}`,
        protocol: 'http',
      },
      middleware,
      messageSocket,
    };
  }

  public async waitForTypeScriptAsync(): Promise<boolean> {
    if (!this.instance) {
      throw new Error('Cannot wait for TypeScript without a running server.');
    }

    return new Promise<boolean>((resolve) => {
      if (!this.metro) {
        // This can happen when the run command is used and the server is already running in another
        // process. In this case we can't wait for the TypeScript check to complete because we don't
        // have access to the Metro server.
        debug('Skipping TypeScript check because Metro is not running (headless).');
        return resolve(false);
      }

      const off = metroWatchTypeScriptFiles({
        projectRoot: this.projectRoot,
        server: this.instance!.server,
        metro: this.metro,
        tsconfig: true,
        throttle: true,
        eventTypes: ['change', 'add'],
        callback: async () => {
          // Run once, this prevents the TypeScript project prerequisite from running on every file change.
          off();
          const { TypeScriptProjectPrerequisite } = await import(
            '../../doctor/typescript/TypeScriptProjectPrerequisite'
          );

          try {
            const req = new TypeScriptProjectPrerequisite(this.projectRoot);
            await req.bootstrapAsync();
            resolve(true);
          } catch (error: any) {
            // Ensure the process doesn't fail if the TypeScript check fails.
            // This could happen during the install.
            Log.log();
            Log.error(
              chalk.red`Failed to automatically setup TypeScript for your project. Try restarting the dev server to fix.`
            );
            Log.exception(error);
            resolve(false);
          }
        },
      });
    });
  }

  public async startTypeScriptServices() {
    typescriptTypeGeneration({
      server: this.instance!.server,
      metro: this.metro,
      projectRoot: this.projectRoot,
    });
  }

  protected getConfigModuleIds(): string[] {
    return ['./metro.config.js', './metro.config.json', './rn-cli.config.js'];
  }
}

function getErrorResult(error: Error) {
  return `
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <title>Error</title>
  </head>
  <body>
    <h1>Failed to render static app</h1>
    <pre>${error.stack}</pre>
  </body>
  </html>
  `;
}

export function getDeepLinkHandler(projectRoot: string): DeepLinkHandler {
  return async ({ runtime }) => {
    if (runtime === 'expo') return;
    const { exp } = getConfig(projectRoot);
    await logEventAsync('dev client start command', {
      status: 'started',
      ...getDevClientProperties(projectRoot, exp),
    });
  };
}
