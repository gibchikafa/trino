/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.trino.plugin.base.security;

import io.trino.spi.TrinoException;

import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static io.trino.spi.StandardErrorCode.CONFIGURATION_INVALID;

public class ReplacePatternMatcher
{
    private final Optional<Pattern> userRegex;
    private final Optional<Pattern> roleRegex;
    private final Optional<Pattern> groupRegex;

    private final String user;
    private final Set<String> roles;
    private final Set<String> groups;

    private final Optional<Matcher> userMatcher;
    private final Optional<Matcher> roleMatcher;
    private final Optional<Matcher> groupMatcher;

    public ReplacePatternMatcher(Optional<Pattern> userRegex, Optional<Pattern> roleRegex, Optional<Pattern> groupRegex, String user, Set<String> roles, Set<String> groups)
    {
        this.userRegex = userRegex;
        this.roleRegex = roleRegex;
        this.groupRegex = groupRegex;

        this.user = user;
        this.roles = roles;
        this.groups = groups;

        this.userMatcher = userRegex.map(regex -> regex.matcher(user));
        this.roleMatcher = roleRegex.flatMap(regex -> roles.stream().map(regex::matcher).filter(Matcher::matches).findAny());
        this.groupMatcher = groupRegex.flatMap(regex -> groups.stream().map(regex::matcher).filter(Matcher::matches).findAny());
    }

    private boolean match()
    {
        return userRegex.map(regex -> regex.matcher(user).matches()).orElse(true) &&
                roleRegex.map(regex -> roles.stream().anyMatch(role -> regex.matcher(role).matches())).orElse(true) &&
                groupRegex.map(regex -> groups.stream().anyMatch(group -> regex.matcher(group).matches())).orElse(true);
    }

    private boolean matchCatalogInternal(final Optional<Pattern> catalogRegex, String catalog)
    {
        validateMatchers(userMatcher, roleMatcher, groupMatcher);

        Optional<Pattern> userReplacedCatalogPattern = replaceRegex(userMatcher, catalogRegex, "catalog", "user");
        Optional<Pattern> roleReplacedCatalogPattern = replaceRegex(roleMatcher, catalogRegex, "catalog", "role");
        Optional<Pattern> groupReplacedCatalogPattern = replaceRegex(groupMatcher, catalogRegex, "catalog", "group");

        return matchPattern(userReplacedCatalogPattern, catalog) || matchPattern(roleReplacedCatalogPattern, catalog)
                || matchPattern(groupReplacedCatalogPattern, catalog);
    }

    public boolean matchCatalog(final Optional<Pattern> catalogRegex, String catalog)
    {
        return match() && matchCatalogInternal(catalogRegex, catalog);
    }

    private boolean matchSchemaInternal(final Optional<Pattern> schemaRegex, String schema)
    {
        validateMatchers(userMatcher, roleMatcher, groupMatcher);

        Optional<Pattern> userReplacedSchemaPattern = replaceRegex(userMatcher, schemaRegex, "schema", "user");
        Optional<Pattern> roleReplacedSchemaPattern = replaceRegex(roleMatcher, schemaRegex, "schema", "role");
        Optional<Pattern> groupReplacedSchemaPattern = replaceRegex(groupMatcher, schemaRegex, "schema", "group");

        return matchPattern(userReplacedSchemaPattern, schema) || matchPattern(roleReplacedSchemaPattern, schema)
                || matchPattern(groupReplacedSchemaPattern, schema);
    }

    public boolean matchSchema(final Optional<Pattern> schemaRegex, String schema)
    {
        return match() && matchSchemaInternal(schemaRegex, schema);
    }

    public boolean matchCatalogAndSchema(final Optional<Pattern> catalogRegex, String catalog, final Optional<Pattern> schemaRegex, String schema)
    {
        return match() && matchCatalogInternal(catalogRegex, catalog) && matchSchemaInternal(schemaRegex, schema);
    }

    private boolean matchTableInternal(final Optional<Pattern> tableRegex, String table)
    {
        validateMatchers(userMatcher, roleMatcher, groupMatcher);

        Optional<Pattern> userReplacedTablePattern = replaceRegex(userMatcher, tableRegex, "table", "user");
        Optional<Pattern> roleReplacedTablePattern = replaceRegex(roleMatcher, tableRegex, "table", "role");
        Optional<Pattern> groupReplacedTablePattern = replaceRegex(groupMatcher, tableRegex, "table", "group");

        return matchPattern(userReplacedTablePattern, table) || matchPattern(roleReplacedTablePattern, table)
                || matchPattern(groupReplacedTablePattern, table);
    }

    public boolean matchTable(final Optional<Pattern> tableRegex, String table)
    {
        return match() && matchTableInternal(tableRegex, table);
    }

    public boolean matchSchemaAndTable(final Optional<Pattern> schemaRegex, String schema, final Optional<Pattern> tableRegex, String table)
    {
        return match() && matchSchemaInternal(schemaRegex, schema) && matchTableInternal(tableRegex, table);
    }

    public boolean matchQueryAccessRule(final Optional<Pattern> queryOwnerRegex, Optional<String> queryOwner)
    {
        if (queryOwner.isEmpty() && queryOwnerRegex.isEmpty()) {
            return true;
        }

        validateMatchers(userMatcher, roleMatcher, groupMatcher);

        Optional<Pattern> userReplacedQueryAccessRulePattern = replaceRegex(userMatcher, queryOwnerRegex, "query_owner", "user");
        Optional<Pattern> roleReplacedQueryAccessRulePattern = replaceRegex(roleMatcher, queryOwnerRegex, "query_owner", "role");
        Optional<Pattern> groupReplacedQueryAccessRulePattern = replaceRegex(groupMatcher, queryOwnerRegex, "query_owner", "group");

        return match() && queryOwner.isPresent() && (matchPattern(userReplacedQueryAccessRulePattern, queryOwner.get())
                || matchPattern(roleReplacedQueryAccessRulePattern, queryOwner.get()) || matchPattern(groupReplacedQueryAccessRulePattern, queryOwner.get()));
    }

    // check if more than one matcher is used to replace patterns
    private void validateMatchers(Optional<Matcher> userMatcher, Optional<Matcher> roleMatcher, Optional<Matcher> groupMatcher)
    {
        if ((userMatcher.isPresent() && userMatcher.get().matches() && userMatcher.get().groupCount() > 0 ? 1 : 0) +
                (roleMatcher.isPresent() && roleMatcher.get().matches() && roleMatcher.get().groupCount() > 0 ? 1 : 0) +
                (groupMatcher.isPresent() && groupMatcher.get().matches() && groupMatcher.get().groupCount() > 0 ? 1 : 0) > 1) {
            throw new TrinoException(CONFIGURATION_INVALID, "Multiple matchers that contain capturing groups are used" +
                    " to replace patterns. This may lead to unexpected results.");
        }
    }

    private Optional<Pattern> replaceRegex(Optional<Matcher> matcher, Optional<Pattern> patternToReplace, String toReplace, String capturingGroup)
    {
        if (matcher.isEmpty()) {
            return patternToReplace;
        }
        if (patternToReplace.isPresent() && patternToReplace.get().pattern().matches(".*\\$\\d+.*")) {
            if (matcher.get().matches() && matcher.get().groupCount() > 0) {
                StringBuilder stringBuilder = new StringBuilder();
                try {
                    matcher.get().appendReplacement(stringBuilder, patternToReplace.get().pattern());
                }
                catch (IndexOutOfBoundsException e) {
                    throw new TrinoException(CONFIGURATION_INVALID,
                            toReplace + " in replace pattern refers to a capturing group that does not exist in " + capturingGroup, e);
                }
                return Optional.of(Pattern.compile(stringBuilder.toString()));
            }
        }
        return patternToReplace;
    }

    private boolean matchPattern(Optional<Pattern> pattern, String value)
    {
        return pattern.map(regex -> regex.matcher(value).matches()).orElse(true);
    }
}
