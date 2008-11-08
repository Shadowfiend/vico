#import "ViTextView.h"
#import "ViLanguageStore.h"
#import "logging.h"

#include <sys/time.h>

@interface ViSyntaxMatch : NSObject
{
	ViRegexpMatch *beginMatch;
	ViRegexpMatch *endMatch;
	NSMutableDictionary *pattern;
	int patternIndex;
	NSUInteger beginLocation;
	NSUInteger beginLength;
}
- (id)initWithMatch:(ViRegexpMatch *)aMatch andPattern:(NSMutableDictionary *)aPattern atIndex:(int)i;
- (NSComparisonResult)sortByLocation:(ViSyntaxMatch *)match;
- (ViRegexp *)endRegexp;
- (NSUInteger)endLocation;
- (NSString *)scope;
- (NSRange)matchedRange;
- (BOOL)isSingleLineMatch;
- (NSString *)description;

@property(readonly) int patternIndex;
@property(readonly) NSMutableDictionary *pattern;
@property(readonly) NSUInteger beginLocation;
@property(readonly) NSUInteger beginLength;
@property(readonly) ViRegexpMatch *beginMatch;
@property(readonly) ViRegexpMatch *endMatch;
@end

@implementation ViSyntaxMatch

@synthesize patternIndex;
@synthesize pattern;
@synthesize beginLocation;
@synthesize beginLength;
@synthesize beginMatch;
@synthesize endMatch;

- (id)initWithMatch:(ViRegexpMatch *)aMatch andPattern:(NSMutableDictionary *)aPattern atIndex:(int)i
{
	self = [super init];
	if (self)
	{
		beginMatch = aMatch;
		pattern = aPattern;
		patternIndex = i;
		if (aMatch)
		{
			beginLocation = [aMatch rangeOfMatchedString].location;
			beginLength = [aMatch rangeOfMatchedString].length;
		}
	}
	return self;
}
- (NSComparisonResult)sortByLocation:(ViSyntaxMatch *)anotherMatch
{
	if ([self beginLocation] < [anotherMatch beginLocation])
		return NSOrderedAscending;
	if ([self beginLocation] > [anotherMatch beginLocation])
		return NSOrderedDescending;
	if ([self patternIndex] < [anotherMatch patternIndex])
		return NSOrderedAscending;
	if ([self patternIndex] > [anotherMatch patternIndex])
		return NSOrderedDescending;
	return NSOrderedSame;
}
- (ViRegexp *)endRegexp
{
	return [pattern objectForKey:@"endRegexp"];
}
- (void)setEndMatch:(ViRegexpMatch *)aMatch
{
	endMatch = aMatch;
}
- (void)setBeginLocation:(NSUInteger)aLocation
{
	// used for continued multi-line matches
	beginLocation = aLocation;
	beginLength = 0;
}
- (NSUInteger)endLocation
{
	if (endMatch)
		return NSMaxRange([endMatch rangeOfMatchedString]);
	else
		return NSMaxRange([beginMatch rangeOfMatchedString]); // FIXME: ???
}
- (NSString *)scope
{
	return [pattern objectForKey:@"name"];
}
- (NSRange)matchedRange
{
	NSRange range = NSMakeRange([self beginLocation], [self endLocation] - [self beginLocation]);
	if (range.length < 0)
	{
		INFO(@"negative length, beginLocation = %u, endLocation = %u", [self beginLocation], [self endLocation]);
		range.length = 0;
	}
	return range;
}
- (BOOL)isSingleLineMatch
{
	return [pattern objectForKey:@"begin"] == nil;
}
- (NSString *)description
{
	return [NSString stringWithFormat:@"ViSyntaxMatch: scope = %@", [self scope]];
}
@end


@interface NSArray (patternArray)
- (BOOL)isEqualToPatternArray:(NSArray *)otherArray;
@end
@implementation NSArray (patternArray)
- (BOOL)isEqualToPatternArray:(NSArray *)otherArray
{
	int i, c = [self count];
	if (otherArray == self)
		return YES;
	if (c != [otherArray count])
		return NO;
	for (i = 0; i < c; i++)
	{
		if ([[self objectAtIndex:i] pattern] != [[otherArray objectAtIndex:i] pattern])
			return NO;
	}
	return YES;
}
@end


@interface ViTextView (syntax_private)
- (ViSyntaxMatch *)highlightLineInRange:(NSRange)aRange continueWithMatch:(ViSyntaxMatch *)continuedMatch characters:(const unichar *)chars;
- (NSArray *)scopesFromMatches:(NSArray *)matches;
- (NSArray *)scopesFromMatches:(NSArray *)matches withoutContentForMatch:(ViSyntaxMatch *)skipContentMatch;
- (void)resetAttributesInRange:(NSRange)aRange;
@end

@implementation ViTextView (syntax)

- (void)addContinuation:(NSArray *)vars
{
	NSArray *continuedMatches = [vars objectAtIndex:0];
	NSRange range = [[vars objectAtIndex:1] rangeValue];
	[[self layoutManager] addTemporaryAttribute:ViContinuationAttributeName value:continuedMatches forCharacterRange:range];
}

- (void)applyScopes:(NSArray *)aScopeArray inRange:(NSRange)aRange withOffset:(NSUInteger)offset
{
	if (aScopeArray == nil)
		return;

	aRange.location += offset;

	NSUInteger l = aRange.location;
	while (l < NSMaxRange(aRange))
	{
		NSRange scopeRange;
		NSMutableArray *oldScopes = [[self layoutManager] temporaryAttribute:ViScopeAttributeName
								 atCharacterIndex:l
							           effectiveRange:&scopeRange];
		// FIXME: the reference says effectiveRange: is more efficient than longestEffectiveRange:, why? Do we miss anything?
							    // longestEffectiveRange:&scopeRange
									  // inRange:NSMakeRange(l, NSMaxRange(aRange) - l)];
		NSMutableArray *scopes = [[NSMutableArray alloc] init];
		if (oldScopes)
		{
			[scopes addObjectsFromArray:oldScopes];
		}
		// append the new scope selector
		[scopes addObjectsFromArray:aScopeArray];

		// apply (merge) the scope selector in the maximum range
		if (scopeRange.location < l)
		{
			scopeRange.length -= l - scopeRange.location;
			scopeRange.location = l;
		}
		if (NSMaxRange(scopeRange) > NSMaxRange(aRange))
			scopeRange.length = NSMaxRange(aRange) - l;

		DEBUG(@"applying scopes [%@] to range %u + %u", [scopes componentsJoinedByString:@" "], scopeRange.location, scopeRange.length);		
		[[self layoutManager] addTemporaryAttribute:ViScopeAttributeName value:scopes forCharacterRange:scopeRange];

		// get the theme attributes for this collection of scopes
		NSDictionary *attributes = [theme attributesForScopes:scopes];
		[[self layoutManager] addTemporaryAttributes:attributes forCharacterRange:scopeRange];

		l = NSMaxRange(scopeRange);
	}
}

- (void)applyContext:(NSMutableArray *)context
{
	struct timeval start;
	struct timeval stop;
	struct timeval diff;
	gettimeofday(&start, NULL);

	// [[NSGarbageCollector defaultCollector] disable];

	NSRange wholeRange = [[context objectAtIndex:0] rangeValue];
	NSUInteger offset = [[context objectAtIndex:1] integerValue];

	DEBUG(@"resetting attributes in range %u + %u", wholeRange.location, wholeRange.length);
	[self resetAttributesInRange:wholeRange];

	[context removeObjectAtIndex:0];
	[context removeObjectAtIndex:0];

	NSArray *foo;
	for (foo in context)
	{
		NSArray *scopes = [foo objectAtIndex:0];
		NSRange range = [[foo objectAtIndex:1] rangeValue];
		[self applyScopes:scopes inRange:range withOffset:offset];
	}

	gettimeofday(&stop, NULL);
	timersub(&stop, &start, &diff);
	unsigned ms = diff.tv_sec * 1000 + diff.tv_usec / 1000;
	INFO(@"applied %u scopes from context  => %.3f s",
		[context count], (float)ms / 1000.0);

	// [[NSGarbageCollector defaultCollector] enable];
}

- (void)applyScopes:(NSArray *)aScopeArray inRange:(NSRange)aRange context:(NSMutableArray *)context
{
	if (aScopeArray == nil)
		return;
	
	NSArray *foo = [NSArray arrayWithObjects:aScopeArray, [NSValue valueWithRange:aRange], nil];
	[context addObject:foo];
}

- (void)applyScope:(NSString *)aScope inRange:(NSRange)aRange context:(NSMutableArray *)context
{
	[self applyScopes:[NSArray arrayWithObject:aScope] inRange:aRange context:context];
}

- (void)highlightCaptures:(NSString *)captureType inPattern:(NSDictionary *)pattern withMatch:(ViRegexpMatch *)aMatch context:(NSMutableArray *)context
{
	NSDictionary *captures = [pattern objectForKey:captureType];
	if (captures == nil)
		captures = [pattern objectForKey:@"captures"];
	if (captures == nil)
		return;

	NSString *key;
	for (key in [captures allKeys])
	{
		NSDictionary *capture = [captures objectForKey:key];
		NSRange r = [aMatch rangeOfSubstringAtIndex:[key intValue]];
		if (r.length > 0)
		{
			DEBUG(@"got capture [%@] at %u + %u", [capture objectForKey:@"name"], r.location, r.length);
			[self applyScope:[capture objectForKey:@"name"] inRange:r context:context];
		}
	}
}

- (void)highlightBeginCapturesInMatch:(ViSyntaxMatch *)aMatch context:(NSMutableArray *)context
{
	[self highlightCaptures:@"beginCaptures" inPattern:[aMatch pattern] withMatch:[aMatch beginMatch] context:context];
}

- (void)highlightEndCapturesInMatch:(ViSyntaxMatch *)aMatch context:(NSMutableArray *)context
{
	[self highlightCaptures:@"endCaptures" inPattern:[aMatch pattern] withMatch:[aMatch endMatch] context:context];
}

- (void)highlightCapturesInMatch:(ViSyntaxMatch *)aMatch context:(NSMutableArray *)context
{
	[self highlightCaptures:@"captures" inPattern:[aMatch pattern] withMatch:[aMatch beginMatch] context:context];
}

- (NSArray *)endMatchesForBeginMatch:(ViSyntaxMatch *)beginMatch inRange:(NSRange)aRange characters:(const unichar *)chars
{
	DEBUG(@"searching for end match to [%@] in range %u + %u",
	      [beginMatch scope], aRange.location, aRange.length);
	
	ViRegexp *endRegexp = [beginMatch endRegexp];
	if (endRegexp == nil)
	{
		INFO(@"************* => compiling pattern with back references for scope [%@]", [beginMatch scope]);
		endRegexp = [language compileRegexp:[[beginMatch pattern] objectForKey:@"end"]
			 withBackreferencesToRegexp:[beginMatch beginMatch]];
	}
	
	if (endRegexp == nil)
	{
		INFO(@"!!!!!!!!! no end regexp?");
		return nil;
	}
	
	// get all matches, one might be overlapped by a subpattern
	regexps_tried++;
	NSArray *matches = nil;
	if (chars)
		matches = [endRegexp allMatchesInCharacters:chars range:aRange start:0];
	else
		matches = [endRegexp allMatchesInString:[storage string] range:aRange start:0];

	regexps_matched += [matches count];

	return matches;
}

- (NSArray *)applyPatterns:(NSArray *)patterns
		   inRange:(NSRange)aRange
	       openMatches:(NSArray *)openMatches
		reachedEOL:(BOOL *)reachedEOL
		matchCache:(NSMutableDictionary *)matchCache
		characters:(const unichar *)chars
	           context:(NSMutableArray *)context
{
	if (reachedEOL)
		*reachedEOL = NO;

	if (aRange.length == 0)
	{
		DEBUG(@"=============== detected zero-length range %u + %u", aRange.location, aRange.length);
		goto done;
	}

	DEBUG(@"searching %i patterns in range %u + %u", [patterns count], aRange.location, aRange.length);

	NSArray *topScopes = [self scopesFromMatches:openMatches];
	
	// keep an array of matches so we can sort it in order to skip overlapping matches
	NSMutableArray *matchingPatterns = [[NSMutableArray alloc] init];
	NSMutableDictionary *pattern;

	ViSyntaxMatch *topOpenMatch = [openMatches lastObject];
	if (topOpenMatch)
	{
		NSArray *endMatches = [self endMatchesForBeginMatch:topOpenMatch inRange:aRange characters:chars];
		DEBUG(@"found %u possible end matches to scope [%@]", [endMatches count], [topOpenMatch scope]);
		ViRegexpMatch *match;
		for (match in endMatches)
		{
			ViSyntaxMatch *m = [[ViSyntaxMatch alloc] initWithMatch:match andPattern:[topOpenMatch pattern] atIndex:0];
			[m setEndMatch:match];
			[matchingPatterns addObject:m];
		}
	}

	int i = 0; // patterns in textmate bundles are ordered so we need to keep track of the index in the patterns array
	for (pattern in patterns)
	{
		/* Match all patterns against this range.
		 */
		ViRegexp *regexp = [pattern objectForKey:@"matchRegexp"];
		if (regexp == nil)
			regexp = [pattern objectForKey:@"beginRegexp"];
		if (regexp == nil)
			continue;
		NSArray *matches;
		matches = [matchCache objectForKey:[NSValue valueWithPointer:pattern]];
		if (matches == nil)
		{
			regexps_tried++;
			if (chars)
				matches = [regexp allMatchesInCharacters:chars range:aRange start:0];
			else
				matches = [regexp allMatchesInString:[storage string] range:aRange start:0];

			regexps_matched += [matches count];
			// INFO(@"caching %i matches for pattern [%@]", [matches count], regexp);
			[matchCache setObject:matches ?: [NSArray array] forKey:[NSValue valueWithPointer:pattern]];

			if ([matches count] == 0)
				DEBUG(@"  matching against pattern %@", [pattern objectForKey:@"name"]);
			else
				DEBUG(@"  matching against pattern %@ = %i matches", [pattern objectForKey:@"name"], [matches count]);
		}
		else
			regexps_cached += [matches count];

		ViRegexpMatch *match;
		for (match in matches)
		{
			ViSyntaxMatch *viMatch = [[ViSyntaxMatch alloc] initWithMatch:match andPattern:pattern atIndex:i];
			[matchingPatterns addObject:viMatch];
		}
				
		++i;
	}
	[matchingPatterns sortUsingSelector:@selector(sortByLocation:)];

	DEBUG(@"applying %u matches in range %u + %u", [matchingPatterns count], aRange.location, aRange.length);
	NSUInteger lastLocation = aRange.location;
	ViSyntaxMatch *aMatch;
	for (aMatch in matchingPatterns)
	{
		if ([aMatch beginLocation] < lastLocation)
		{
			// skip overlapping matches
			regexps_overlapped++;
			DEBUG(@"skipping overlapping match for [%@] at %u + %u", [aMatch scope], [aMatch beginLocation], [aMatch beginLength]);
			continue;
		}

		if ([aMatch beginLocation] > lastLocation)
		{
			// Apply current scopes before adding the new match
			[self applyScopes:topScopes inRange:NSMakeRange(lastLocation, [aMatch beginLocation] - lastLocation) context:context];
		}

		if ([aMatch isSingleLineMatch])
		{
			DEBUG(@"got match on [%@] at %u + %u (subpattern)",
			      [aMatch scope],
			      [[aMatch beginMatch] rangeOfMatchedString].location,
			      [[aMatch beginMatch] rangeOfMatchedString].length);
			if ([aMatch scope])
			{
				/* We might not have a scope for the whole match. There is probably only captures, which is ok. */
				[self applyScopes:[topScopes arrayByAddingObject:[aMatch scope]] inRange:[aMatch matchedRange] context:context];
			}
			[self highlightCapturesInMatch:aMatch context:context];
		}
		else if ([aMatch endMatch])
		{
			[topOpenMatch setEndMatch:[aMatch endMatch]];
			DEBUG(@"got end match on [%@] at %u + %u",
			      [aMatch scope],
			      [[aMatch endMatch] rangeOfMatchedString].location,
			      [[aMatch endMatch] rangeOfMatchedString].length);

			topScopes = [self scopesFromMatches:openMatches withoutContentForMatch:topOpenMatch];
			[self applyScopes:topScopes inRange:[[aMatch endMatch] rangeOfMatchedString] context:context];
			[self highlightEndCapturesInMatch:aMatch context:context];
			// [self performSelectorOnMainThread:@selector(highlightEndCapturesInMatch:) withObject:aMatch waitUntilDone:NO];

			// pop one or more open matches off the stack and return the rest
			while ([openMatches count] > 0)
			{
				openMatches = [openMatches subarrayWithRange:NSMakeRange(0, [openMatches count] - 1)];
				topOpenMatch = [openMatches lastObject];
				if (topOpenMatch == nil)
					break;
				NSArray *endMatches = [self endMatchesForBeginMatch:topOpenMatch inRange:[[aMatch endMatch] rangeOfMatchedString] characters:chars];
				// if the next top open match also matches the end range,
				// and it is a look-ahead match, keep popping off open matches
				if (endMatches == nil || [[endMatches objectAtIndex:0] rangeOfMatchedString].length != 0)
					break;
			}
			
			DEBUG(@"returning %i continuation matches", [openMatches count]);
			return [openMatches count] > 0 ? openMatches : nil;
		}
		else
		{
			DEBUG(@"got begin match on [%@] at %u + %u", [aMatch scope], [aMatch beginLocation], [aMatch beginLength]);
			NSArray *newTopScopes = [aMatch scope] ? [topScopes arrayByAddingObject:[aMatch scope]] : topScopes;
			[self applyScopes:newTopScopes inRange:[[aMatch beginMatch] rangeOfMatchedString] context:context];
			// search for end match from after the begin match to EOL
			NSRange range = aRange;
			range.location = NSMaxRange([[aMatch beginMatch] rangeOfMatchedString]);
			range.length = NSMaxRange(aRange) - range.location;
			logIndent++;
			BOOL tmpEOL = NO;
			NSArray *continuationMatches = [self applyPatterns:[language expandedPatternsForPattern:[aMatch pattern]]
								   inRange:range
							       openMatches:[openMatches arrayByAddingObject:aMatch]
								reachedEOL:&tmpEOL
								matchCache:matchCache
								characters:chars
							           context:context];
			logIndent--;
			// need to highlight captures _after_ the main pattern has been highlighted
			[self highlightBeginCapturesInMatch:aMatch context:context];
			if (tmpEOL == YES)
			{
				if (reachedEOL)
					*reachedEOL = YES;
				DEBUG(@"returning %i continuation matches", [continuationMatches count]);
				return continuationMatches;
			}
		}
		lastLocation = [aMatch endLocation];
		// just stop if we passed our line range
		if (lastLocation >= NSMaxRange(aRange))
		{
			DEBUG(@"skipping further matches as we passed our line range");
			break;
		}
	}

	if (lastLocation < NSMaxRange(aRange))
		[self applyScopes:topScopes inRange:NSMakeRange(lastLocation, NSMaxRange(aRange) - lastLocation) context:context];

done:
	if (reachedEOL)
		*reachedEOL = YES;

	if (openMatches)
	{
		DEBUG(@"returning %i continuation matches", [openMatches count]);
		return openMatches;
	}
	return nil;
}

- (NSArray *)scopesFromMatches:(NSArray *)matches withoutContentForMatch:(ViSyntaxMatch *)skipContentMatch
{
	NSMutableArray *scopes = [[NSMutableArray alloc] init];
	ViSyntaxMatch *m;
	for (m in matches)
	{
		if ([m scope])
			[scopes addObject:[m scope]];
		if (m != skipContentMatch)
		{
			NSString *contentName = [[m pattern] objectForKey:@"contentName"];
			if (contentName)
			{
				[scopes addObject:contentName];
			}
		}
	}

	DEBUG(@"got scopes [%@]", [scopes componentsJoinedByString:@" "]);
	return scopes;
}

- (NSArray *)scopesFromMatches:(NSArray *)matches
{
	return [self scopesFromMatches:matches withoutContentForMatch:nil];
}

- (NSArray *)highlightLineInRange:(NSRange)aRange
              continueWithMatches:(NSArray *)continuedMatches
                       characters:(const unichar *)chars
                          context:(NSMutableArray *)context
{
	DEBUG(@"-----> line range = %u (%u) + %u", aRange.location, aRange.location, aRange.length);
	NSUInteger lastLocation = aRange.location;

	NSMutableDictionary *matchCache = [[NSMutableDictionary alloc] init];

	// should we continue on multi-line matches?
	BOOL reachedEOL = NO;
	while ([continuedMatches count] > 0)
	{
		DEBUG(@"continuing with match [%@] (of %i total)", [[continuedMatches lastObject] scope], [continuedMatches count]);

		ViSyntaxMatch *m;
		for (m in continuedMatches)
		{
			[m setBeginLocation:aRange.location];
		}

		ViSyntaxMatch *topMatch = [continuedMatches lastObject];

		continuedMatches = [self applyPatterns:[language expandedPatternsForPattern:[topMatch pattern]]
					       inRange:aRange
					   openMatches:continuedMatches
					    reachedEOL:&reachedEOL
					    matchCache:matchCache
					    characters:chars
					       context:context];

		if (reachedEOL)
			return continuedMatches;
		lastLocation = [topMatch endLocation];

		// adjust the line range
		if (lastLocation >= NSMaxRange(aRange))
			return nil;
		aRange.length = NSMaxRange(aRange) - lastLocation;
		aRange.location = lastLocation;
	}

	// search top-level patterns
	return [self applyPatterns:[language patterns]
	                   inRange:aRange
	               openMatches:[NSArray array]
	                reachedEOL:nil
	                 matchCache:matchCache
	                 characters:chars
	                    context:context];
}

- (NSArray *)continuedMatchesForLocation:(NSUInteger)location
{
	NSArray *continuedMatches = [[self layoutManager] temporaryAttribute:ViContinuationAttributeName
							    atCharacterIndex:IMAX(0, location - 1)
							      effectiveRange:NULL];
	if (continuedMatches)
		DEBUG(@"detected %i previous scopes at location %u", [continuedMatches count], location);
	return continuedMatches;
}

- (void)resetAttributesInRange:(NSRange)aRange
{
	[[self layoutManager] removeTemporaryAttribute:ViScopeAttributeName forCharacterRange:aRange];
	[[self layoutManager] removeTemporaryAttribute:ViContinuationAttributeName forCharacterRange:aRange];
	// [[self layoutManager] removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:aRange];
	// [[self layoutManager] removeTemporaryAttribute:NSFontAttributeName forCharacterRange:aRange];
	[[self layoutManager] removeTemporaryAttribute:NSUnderlineStyleAttributeName forCharacterRange:aRange];
	[[self layoutManager] removeTemporaryAttribute:NSObliquenessAttributeName forCharacterRange:aRange];
	[[self layoutManager] removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:aRange];
	
	NSDictionary *defaultAttributes = nil;
	if (language)
	{
		defaultAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
					  [theme foregroundColor], NSForegroundColorAttributeName,
					  [NSArray arrayWithObject:[language name]], ViScopeAttributeName,
					  nil];
	}
	else
	{
		// FIXME: shouldn't typing attributes apply when, like, typing!?
		NSDictionary *typingAttributes = [self typingAttributes];
		NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:
					    [typingAttributes objectForKey:NSParagraphStyleAttributeName], NSParagraphStyleAttributeName,
					    [theme foregroundColor], NSForegroundColorAttributeName,
					    [self font], NSFontAttributeName,
					    nil];
		[storage addAttributes:attributes range:aRange];
		return;
/*		defaultAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
				     [theme foregroundColor], NSForegroundColorAttributeName,
				     nil];
 */
	}

	[[self layoutManager] addTemporaryAttributes:defaultAttributes forCharacterRange:aRange];
}

- (void)highlightRange:(NSRange)aRange continueWithMatches:(NSArray *)continuedMatches characters:(unichar *)chars startLocation:(NSUInteger)startLocation
{
	struct timeval start;
	struct timeval stop_time;
	struct timeval diff;
	gettimeofday(&start, NULL);

	regexps_tried = 0;
	regexps_overlapped = 0;
	regexps_matched = 0;
	regexps_cached = 0;

	BOOL extendedRange = NO;
	NSUInteger lineno = 1;

	[[NSGarbageCollector defaultCollector] disable];

	NSMutableArray *context = [[NSMutableArray alloc] init];
	[context addObject:[NSValue valueWithRange:aRange]];
	[context addObject:[NSNumber numberWithUnsignedInteger:startLocation]];

	DEBUG(@"highlighting range %u(%u) + %u", aRange.location, startLocation + aRange.location, aRange.length);
	
	// highlight each line separately
	NSUInteger lastScopeUpdate = aRange.location;
	NSUInteger nextRange = aRange.location;
	while (nextRange < NSMaxRange(aRange))
	{
		NSUInteger end = nextRange;
		if (chars)
		{
			while (end < NSMaxRange(aRange) && chars[end] != '\n')
				++end;
			if (end < NSMaxRange(aRange))
				++end;
			if (end > NSMaxRange(aRange))
				end = NSNotFound;
		}
		else
		{
			[self getLineStart:NULL end:&end contentsEnd:NULL forLocation:nextRange];
		}
		if (end == nextRange || end == NSNotFound)
			break;
		NSRange line = NSMakeRange(nextRange, end - nextRange);

		DEBUG(@"---> line number %i", lineno);

#if 0
		if (extendedRange)
		{
			lastContinuedMatches = [self continuedMatchesForLocation:end];
			[self resetAttributesInRange:line];
		}
#endif

		continuedMatches = [self highlightLineInRange:line continueWithMatches:continuedMatches characters:chars context:context];
		nextRange = end;

		if (continuedMatches)
		{
			/* Mark the EOL character with the continuation patterns */
			// [[self layoutManager] addTemporaryAttribute:ViContinuationAttributeName value:continuedMatches forCharacterRange:NSMakeRange(end - 1, 1)];
			[self performSelectorOnMainThread:@selector(addContinuation:)
			                       withObject:[NSArray arrayWithObjects:continuedMatches, [NSValue valueWithRange:NSMakeRange(startLocation + end - 1, 1)], nil]
			                    waitUntilDone:NO];
		}

#if 0
		if (isRestarting && (extendedRange || nextRange >= NSMaxRange(aRange)) /*&& nextRange < [storage length]*/)
		{
			BOOL continuationMatchesHaveChanged = ![continuedMatches isEqualToPatternArray:lastContinuedMatches];
			if (continuationMatchesHaveChanged)
			{
				if (!extendedRange)
				{
					DEBUG(@"continuation matches at location %u have changed, and this is an incremental update", end);
					aRange.length = [storage length] - aRange.location;
					extendedRange = YES;
				}
			}
			else if (extendedRange)
			{
				DEBUG(@"extended range and continuation matches are UNchanged, we're done at location %i (EOF = %i)",
				      nextRange, [storage length]);
				break;
			}
		}
#endif
		
		lineno++;
		if (lineno % 100 == 0)
		{
			NSMutableArray *contextCopy = [NSMutableArray arrayWithArray:context];
			[contextCopy replaceObjectAtIndex:0 withObject:[NSValue valueWithRange:NSMakeRange(lastScopeUpdate, nextRange - lastScopeUpdate)]];
			[self performSelectorOnMainThread:@selector(applyContext:) withObject:contextCopy waitUntilDone:NO];
			[context removeObjectsInRange:NSMakeRange(2, [context count] - 2)];
			lastScopeUpdate = nextRange;
		}
	}

	free(chars);

	gettimeofday(&stop_time, NULL);
	timersub(&stop_time, &start, &diff);
	unsigned ms = diff.tv_sec * 1000 + diff.tv_usec / 1000;
	INFO(@"regexps tried: %u, matched: %u, overlapped: %u, cached: %u    => %.3f s",
		regexps_tried, regexps_matched, regexps_overlapped, regexps_cached, (float)ms / 1000.0);

	[context replaceObjectAtIndex:0 withObject:[NSValue valueWithRange:NSMakeRange(lastScopeUpdate, nextRange - lastScopeUpdate)]];
	[self performSelectorOnMainThread:@selector(applyContext:) withObject:context waitUntilDone:NO];

	[[NSGarbageCollector defaultCollector] enable];
}

- (void)highlightInBackground:(NSArray *)vars
{
	NSRange range = [[vars objectAtIndex:0] rangeValue];
	unichar *chars = [[vars objectAtIndex:1] pointerValue];
	NSArray *continuedMatches = nil;
	if ([vars count] > 2)
		continuedMatches = [vars objectAtIndex:2];

	INFO(@"highlighting in background thread");
	[self highlightRange:NSMakeRange(0, range.length) continueWithMatches:continuedMatches characters:chars startLocation:0];
}

- (void)highlightRange:(NSRange)aRange inBackground:(BOOL)inBackground
{
	// if we're restarting, detect the previous scope so we can continue on a multi-line pattern, if any
	NSArray *continuedMatches = nil;
	if (aRange.location > 0)
	{
		continuedMatches = [self continuedMatchesForLocation:aRange.location];
	}

	NSArray *lastContinuedMatches = nil;
#if 0
	if (isRestarting)
	{
		lastContinuedMatches = [self continuedMatchesForLocation:NSMaxRange(aRange)];
	}
#endif

	if (language)
	{
	
		if (inBackground)
		{
			INFO(@"allocating %u bytes", [storage length] * sizeof(unichar));
			unichar *chars = malloc([storage length] * sizeof(unichar));
			[[storage string] getCharacters:chars];

			[self performSelectorInBackground:@selector(highlightInBackground:)
					       withObject:[NSArray arrayWithObjects:[NSValue valueWithRange:aRange], [NSValue valueWithPointer:chars], continuedMatches, nil]];
		}
		else
		{
			[self highlightRange:aRange continueWithMatches:continuedMatches characters:NULL startLocation:0];
		}
	}
}

- (void)highlightInWrappedRange:(NSValue *)wrappedRange
{
	[self highlightRange:[wrappedRange rangeValue] inBackground:NO];
}

/*
 * Update syntax colors.
 */
- (void)textStorageDidProcessEditing:(NSNotification *)notification
{
	NSRange area = [storage editedRange];
	
	if (language == nil)
	{
		[self resetAttributesInRange:NSMakeRange(0, [storage length])];
		return;
	}
	
	// extend our range along line boundaries.
	NSUInteger bol, eol;
	[[storage string] getLineStart:&bol end:&eol contentsEnd:NULL forRange:area];
	area.location = bol;
	area.length = eol - bol;

	if (area.length == 0)
		return;

	// temporary attributes don't work right when called from a notification
	// FIXME: try call this in - (void)layoutManagerDidInvalidateLayout:(NSLayoutManager *)sender instead
	[self performSelector:@selector(highlightInWrappedRange:) withObject:[NSValue valueWithRange:area] afterDelay:0.0];
}

- (void)highlightEverything
{
	if (language == nil)
	{
		[self resetAttributesInRange:NSMakeRange(0, [storage length])];
		return;
	}
	DEBUG(@"start highlighting file");
	[storage beginEditing];
	[self highlightRange:NSMakeRange(0, [storage length]) inBackground:YES];
	[storage endEditing];
	DEBUG(@"finished highlighting file");
}

@end
