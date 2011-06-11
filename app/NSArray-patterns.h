@interface NSArray (patterns)

- (BOOL)isEqualToPatternArray:(NSArray *)otherArray;
- (BOOL)isEqualToStringArray:(NSArray *)otherArray;
- (NSString *)bestMatchForScopes:(NSArray *)scopes;
- (BOOL)hasPrefix:(NSArray *)otherArray;
- (u_int64_t)matchesSelector:(NSString *)selector;

@end

