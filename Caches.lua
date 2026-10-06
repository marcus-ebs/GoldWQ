-- Each cache = list of quest IDs. A quest flagged complete this week counts toward that cache.
GoldWQ_Caches = {
    {
        name = "Apex Cache",
        quests = {
            95842, -- Midnight: Void Assaults
            93889, 93767, 93909, 93769, 93766, 93910, 93892, 93911, 94457,
        },
    },
    {
        name = "Overflowing Abundant Satchel",
        quests = { 89507 }, -- Abundant Offerings (Zul'Aman)
    },
    {
        name = "Avid Learner's Supply Pack",
        quests = { 89268, 92716, 92719, 92721, 92722, 92720, 92724, 92725 },
        -- 89268 Lost Legends (first time); 927xx blue repeatable versions after clearing the main story
    },
    {
        name = "Saltheril's Soiree cache",
        quests = { 92114, 90573, 90574, 90575, 90576 }, -- Saltheril's Soiree (Eversong); 90574 = Fortify the Runestones (gives the cache). 91966 removed: it is the daily party quest, not the cache quest
    },
    {
        name = "Stormarion Assault cache",
        quests = { 94581 }, -- unconfirmed ID, Marcus believes this is right
    },
    {
        name = "Curse Surge cache",
        quests = { 96995 }, -- Turn Back the Surge
    },
}

-- The Midnight Special Assignments (locked capstone world quests).
-- quest  = the assignment itself
-- unlock = the placeholder quest the game shows while it is still locked
GoldWQ_SpecialAssignments = {
    { name = "The Grand Magister's Drink",      zone = "Eversong Woods",  quest = 92145, unlock = 92848 },
    { name = "Shade and Claw",                  zone = "Eversong Woods",  quest = 92139, unlock = 95435 },
    { name = "What Remains of a Temple Broken", zone = "Zul'Aman",        quest = 91390, unlock = 94865 },
    { name = "Ours Once More!",                 zone = "Zul'Aman",        quest = 91796, unlock = 94866 },
    { name = "A Hunter's Regret",               zone = "Harandar",        quest = 92063, unlock = 94390 },
    { name = "Push Back the Light",             zone = "Harandar",        quest = 93013, unlock = 94391 },
    { name = "Precision Excision",              zone = "Voidstorm",       quest = 93438, unlock = 94743 },
    { name = "Agents of the Shield",            zone = "Voidstorm",       quest = 93244, unlock = 94795 },
    { name = "Wraith Wrath",                    zone = "The Coiled Isle", quest = 95918, unlock = 96307 },
    { name = "Demand and Supply",               zone = "The Coiled Isle", quest = 95921, unlock = 96492 },
    { name = "Face the Swarm",                  zone = "The Coiled Isle", quest = 95922, unlock = 96029 },
}
