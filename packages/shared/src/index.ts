export type CheckType = 'http' | 'tcp';
export type AuthType = 'none' | 'bearer_token' | 'basic_auth' | 'custom_header';
export type MatchMode = 'exact' | 'contains' | 'regex';

export interface JsonAssertion {
  path: string;
  expectedValue: string;
  matchMode: MatchMode;
}
